import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const DEFAULT_BASE_URL = "http://127.0.0.1:8765";
const DEFAULT_TIMEOUT_MS = 15000;

function resolvePluginConfig(api) {
  const config = api.pluginConfig && typeof api.pluginConfig === "object" ? api.pluginConfig : {};
  return {
    baseUrl: String(config.baseUrl || process.env.PERSONAL_ASSISTANT_URL || DEFAULT_BASE_URL).replace(/\/+$/, ""),
    timeoutMs: Number(config.timeoutMs || process.env.PERSONAL_ASSISTANT_TIMEOUT_MS || DEFAULT_TIMEOUT_MS),
  };
}

async function postAssistantMessage(baseUrl, timeoutMs, message) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`${baseUrl}/openclaw/message`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message }),
      signal: controller.signal,
    });
    const text = await response.text();
    let payload;
    try {
      payload = text ? JSON.parse(text) : {};
    } catch {
      payload = { reply: text };
    }
    if (!response.ok) {
      throw new Error(`Personal Assistant HTTP ${response.status}: ${payload.error || text}`);
    }
    return payload;
  } finally {
    clearTimeout(timeout);
  }
}

export default definePluginEntry({
  id: "personal-assistant",
  name: "Personal Assistant",
  description: "SQLite-backed personal note logging, retrieval, analytics, and temporary Markdown reports.",
  register(api) {
    api.registerTool({
      name: "personal_assistant",
      label: "Personal Assistant",
      description:
        "Use this tool whenever the user asks to log, remember, record, retrieve, find, show, count, average, analyze, summarize, or generate a Markdown report for personal notes. It stores and reads from the user's SQLite source of truth.",
      parameters: {
        type: "object",
        required: ["message"],
        additionalProperties: false,
        properties: {
          message: {
            type: "string",
            description:
              "The user's full natural-language note, retrieval request, analytics request, or report request.",
          },
        },
      },
      async execute(_id, params) {
        const { baseUrl, timeoutMs } = resolvePluginConfig(api);
        const result = await postAssistantMessage(baseUrl, timeoutMs, String(params.message || ""));
        return {
          content: [
            {
              type: "text",
              text: result.reply || JSON.stringify(result),
            },
          ],
          structuredContent: result,
        };
      },
    });
  },
});
