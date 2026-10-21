// Minimal klient för OpenRouters chat completions (OPENROUTER_API_KEY).

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const REQUEST_TIMEOUT_MS = 300_000;

/** Primär modell först; OpenRouter faller tillbaka på nästa vid fel eller överbelastning. */
export const MODELS = ["anthropic/claude-opus-5.5", "anthropic/claude-opus-5"];

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

export async function chat(request: ChatRequest): Promise<ChatResult> {
  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) throw new AIError("OPENROUTER_API_KEY saknas i Supabase (Edge Functions → Secrets).");

  const body: Record<string, unknown> = {
    models: MODELS,
    max_tokens: request.maxTokens,
    reasoning: { effort: request.effort },
    messages: request.messages,
  };
  if (request.responseFormat) {
    body.response_format = {
      type: "json_schema",
      json_schema: { name: request.responseFormat.name, strict: true, schema: request.responseFormat.schema },
    };
    // Skicka bara till leverantörer som faktiskt stöder strukturerad output.
    body.provider = { require_parameters: true };
  }
  if (request.tools) {
    body.tools = request.tools.map((t) => ({ type: "function", function: t }));
    body.tool_choice = "auto";
  }

  let response: Response;
  try {
    response = await fetch(OPENROUTER_URL, {
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
    throw new AIError(errorText(response.status, result.error?.message));
  }
  const choice = result.choices?.[0];
  if (choice?.finish_reason === "length") {
    throw new AIError("Svaret blev för långt och avbröts. Försök igen.");
  }
  if (choice?.finish_reason === "content_filter") {
    throw new AIError("AI-coachen avböjde att svara. Försök formulera om dig.");
  }
  return {
    content: choice?.message?.content?.trim() ?? "",
    toolCalls: choice?.message?.tool_calls ?? [],
    model: result.model ?? MODELS[0],
  };
}

function errorText(status: number, message?: string): string {
  switch (status) {
    case 401:
      return "Fel API-nyckel för OpenRouter (OPENROUTER_API_KEY).";
    case 402:
      return "Slut på krediter hos OpenRouter. Fyll på på openrouter.ai.";
    case 429:
      return "AI-tjänsten är överbelastad just nu. Försök igen om en stund.";
    default:
      return `AI-tjänsten svarade med fel ${status}${message ? `: ${message}` : ""}.`;
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
