// Forge embeds this app at /rivet/ and serves every model the user can run —
// local weights plus keyed cloud providers — from the same origin's /v1/models.
// Cloud ids are provider-prefixed ("anthropic/claude-…"); Forge forwards them.

export type ForgeModel = { id: string; name: string; provider: string };

export const forgeLoadedLocalModel = 'forge/local';

export const isForgeEmbedded = (): boolean =>
  typeof globalThis.location !== 'undefined' && globalThis.location.pathname.startsWith('/rivet/');

let cached: { at: number; models: ForgeModel[] } | undefined;

export async function fetchForgeModels(): Promise<ForgeModel[]> {
  if (cached && Date.now() - cached.at < 15_000) {
    return cached.models;
  }
  try {
    const response = await fetch(`${globalThis.location.origin}/v1/models`);
    const json = (await response.json()) as { data?: { id: string; name?: string; owned_by?: string }[] };
    const models = (json.data ?? []).map((model) => ({
      id: model.id,
      name: model.name ?? model.id,
      provider: model.owned_by === 'forge' ? 'Local' : (model.owned_by ?? 'Other'),
    }));
    cached = { at: Date.now(), models };
    return models;
  } catch {
    return cached?.models ?? [];
  }
}
