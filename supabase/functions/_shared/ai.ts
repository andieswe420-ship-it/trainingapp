// AI-anrop via OpenAI-kompatibla chat completions. Leverantör väljs med Edge Function-secrets:
// - AI_PROVIDER: "openrouter" (standard) eller "berget"
// - OPENROUTER_API_KEY: nyckel till OpenRouter (Claude)
// - BERGET_API_KEY + BERGET_MODEL: nyckel och modell hos Berget AI (Stockholm)
// Med Berget som leverantör används OpenRouter som reserv om Berget svarar med fel.

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const BERGET_URL = "https://api.berget.ai/v1/chat/completions";
const REQUEST_TIMEOUT_MS = 300_000;

/** OpenRouter: primär modell först; OpenRouter faller tillbaka på nästa vid fel eller överbelastning. */
const OPENROUTER_MODELS = ["anthropic/claude-opus-5.5", "anthropic/claude-opus-5"];
const DEFAULT_BERGET_MODEL = "moonshotai/Kimi-K3";
/** Bergets modeller har mindre kontextfönster än Claude – begränsa svarslängden. */
const BERGET_MAX_TOKENS = 16384;

type Provider = "openrouter" | "berget";

/** Fel med ett meddelande som kan visas för användaren. */
export class AIError extends Error {}

export type ContentPart = { type: "text"; text: string; cache_control?: { type: "ephemeral" } };

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string | ContentPart[];
}

export interface ToolCall {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
}

export interface ChatRequest {
  messages: ChatMessage[];
  effort: "low" | "medium" | "high";
  maxTokens: number;
  responseFormat?: { name: string; schema: Record<string, unknown> };
  tools?: { name: string; description: string; parameters: Record<string, unknown> }[];
}

export interface ChatResult {
  content: string;
  toolCalls: ToolCall[];
  model: string;
}

interface ChatCompletion {
  model?: string;
  choices?: {
    finish_reason?: string | null;
    message?: { content?: string | null; tool_calls?: ToolCall[] };
  }[];
  error?: { code?: number | string; message?: string };
}

function provider(): Provider {
  return Deno.env.get("AI_PROVIDER")?.trim().toLowerCase() === "berget" ? "berget" : "openrouter";
}

function bergetModel(): string {
  return Deno.env.get("BERGET_MODEL")?.trim() || DEFAULT_BERGET_MODEL;
}

/** Modellen som förväntas svara – sparas på rader som skapas innan svaret finns. */
export function defaultModel(): string {
  return provider() === "berget" ? `berget/${bergetModel()}` : OPENROUTER_MODELS[0];
}

export async function chat(request: ChatRequest): Promise<ChatResult> {
  if (provider() === "berget") {
    try {
      return await callBerget(request);
    } catch (err) {
      if (!Deno.env.get("OPENROUTER_API_KEY")) throw err;
      console.error("Berget AI misslyckades, använder OpenRouter som reserv", err);
    }
  }
  return await callOpenRouter(request);
}

async function callOpenRouter(request: ChatRequest): Promise<ChatResult> {
  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) throw new AIError("OPENROUTER_API_KEY saknas i Supabase (Edge Functions → Secrets).");

  const body: Record<string, unknown> = {
    models: OPENROUTER_MODELS,
    max_tokens: request.maxTokens,
    reasoning: { effort: request.effort },
    messages: request.messages,
  };
  if (request.responseFormat) {
    // Skicka bara till leverantörer som faktiskt stöder strukturerad output.
    body.provider = { require_parameters: true };
  }
  return await send("OpenRouter", OPENROUTER_URL, apiKey, withFormatAndTools(body, request), OPENROUTER_MODELS[0]);
}

async function callBerget(request: ChatRequest): Promise<ChatResult> {
  const apiKey = Deno.env.get("BERGET_API_KEY");
  if (!apiKey) throw new AIError("BERGET_API_KEY saknas i Supabase (Edge Functions → Secrets).");
  const model = bergetModel();

  const body: Record<string, unknown> = {
    model,
    max_tokens: Math.min(request.maxTokens, BERGET_MAX_TOKENS),
    // cache_control är OpenRouter/Anthropic-specifikt – skicka vanlig text.
    messages: request.messages.map((m) => ({
      role: m.role,
      content: typeof m.content === "string" ? m.content : m.content.map((part) => part.text).join("\n\n"),
    })),
  };
  const result = await send("Berget AI", BERGET_URL, apiKey, withFormatAndTools(body, request), model);
  return { ...result, model: `berget/${result.model}` };
}

function withFormatAndTools(body: Record<string, unknown>, request: ChatRequest): Record<string, unknown> {
  if (request.responseFormat) {
    body.response_format = {
      type: "json_schema",
      json_schema: { name: request.responseFormat.name, strict: true, schema: request.responseFormat.schema },
    };
  }
  if (request.tools) {
    body.tools = request.tools.map((t) => ({ type: "function", function: t }));
    body.tool_choice = "auto";
  }
  return body;
}

async function send(
  name: string,
  url: string,
  apiKey: string,
  body: Record<string, unknown>,
  fallbackModel: string,
): Promise<ChatResult> {
  let response: Response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "X-Title": "TrainingApp",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (err) {
    if (err instanceof DOMException && err.name === "TimeoutError") {
      throw new AIError("AI-tjänsten svarade inte i tid. Försök igen.");
    }
    throw err;
  }

  const result = await response.json().catch(() => ({})) as ChatCompletion;
  if (!response.ok || result.error) {
    throw new AIError(errorText(name, response.status, result.error?.message));
  }
  const choice = result.choices?.[0];
  if (choice?.finish_reason === "length") {
    throw new AIError("Svaret blev för långt och avbröts. Försök igen.");
  }
  if (choice?.finish_reason === "content_filter") {
    throw new AIError("AI-coachen avböjde att svara. Försök formulera om dig.");
  }
  const toolCalls = choice?.message?.tool_calls ?? [];
  console.log(`${name} svarade: ${result.model ?? fallbackModel}, finish_reason=${choice?.finish_reason}, ` +
    `verktyg=${toolCalls.map((c) => c.function.name).join(",") || "inga"}`);
  return {
    content: stripThinking(choice?.message?.content ?? ""),
    toolCalls,
    model: result.model ?? fallbackModel,
  };
}

/** Vissa öppna modeller skriver ut sitt resonemang i <think>-taggar före svaret. */
function stripThinking(text: string): string {
  return text.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
}

function errorText(name: string, status: number, message?: string): string {
  switch (status) {
    case 401:
      return `Fel API-nyckel för ${name}.`;
    case 402:
      return `Slut på krediter hos ${name}.`;
    case 429:
      return "AI-tjänsten är överbelastad just nu. Försök igen om en stund.";
    default:
      return `${name} svarade med fel ${status}${message ? `: ${message}` : ""}.`;
  }
}

export function errorMessage(err: unknown): string {
  if (err instanceof AIError) return err.message;
  return err instanceof Error ? err.message : String(err);
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
