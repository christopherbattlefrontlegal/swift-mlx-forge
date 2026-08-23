import type { MCP, MCPProvider } from '@ironclad/rivet-core';

type ForgeTool = {
  server: string;
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
};

export class ForgeMCPProvider implements MCPProvider {
  private async tools(): Promise<ForgeTool[]> {
    const response = await fetch(`${globalThis.location.origin}/v1/forge/mcp/tools`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    });
    if (!response.ok) {
      throw new Error(`Forge MCP discovery failed (${response.status})`);
    }
    const payload = (await response.json()) as { tools?: ForgeTool[] };
    return payload.tools ?? [];
  }

  async getStdioTools(
    _clientConfig: { name: string; version: string },
    serverConfig: MCP.ServerConfigWithId,
  ): Promise<MCP.Tool[]> {
    return (await this.tools())
      .filter((tool) => tool.server === serverConfig.serverId)
      .map((tool) => ({
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema ?? { type: 'object', properties: {} },
      }));
  }

  async stdioToolCall(
    _clientConfig: { name: string; version: string },
    serverConfig: MCP.ServerConfigWithId,
    toolCall: MCP.ToolCallRequest,
  ): Promise<MCP.ToolCallResponse> {
    const response = await fetch(`${globalThis.location.origin}/v1/forge/mcp/call`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        server: serverConfig.serverId,
        tool: toolCall.name,
        arguments: toolCall.arguments ?? {},
      }),
    });
    const payload = await response.json().catch(() => undefined);
    if (!response.ok) {
      const message = (payload as { error?: { message?: string } } | undefined)?.error?.message;
      throw new Error(message || `Forge MCP tool call failed (${response.status})`);
    }
    return payload as MCP.ToolCallResponse;
  }

  getHTTPTools(): Promise<MCP.Tool[]> {
    return this.unsupportedHTTP();
  }

  httpToolCall(): Promise<MCP.ToolCallResponse> {
    return this.unsupportedHTTP();
  }

  getHTTPrompts(): Promise<MCP.Prompt[]> {
    return this.unsupportedHTTP();
  }

  getStdioPrompts(): Promise<MCP.Prompt[]> {
    return Promise.reject(new Error('Forge MCP prompt discovery is not implemented yet.'));
  }

  getHTTPrompt(): Promise<MCP.GetPromptResponse> {
    return this.unsupportedHTTP();
  }

  getStdioPrompt(): Promise<MCP.GetPromptResponse> {
    return Promise.reject(new Error('Forge MCP prompt retrieval is not implemented yet.'));
  }

  private unsupportedHTTP<T>(): Promise<T> {
    return Promise.reject(
      new Error('Configure the HTTP MCP server in Forge settings, then select it by server ID using STDIO mode.'),
    );
  }
}
