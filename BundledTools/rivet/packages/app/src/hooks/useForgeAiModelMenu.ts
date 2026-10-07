import { useEffect, useMemo, useState } from 'react';
import { type ForgeModel, fetchForgeModels, forgeLoadedLocalModel, isForgeEmbedded } from '@ironclad/rivet-core';
import { type ContextMenuItem } from './useContextMenuConfiguration';

/**
 * "Add AI Model" submenu: provider → model, from Forge's live catalog. Picking one
 * drops a Chat block already pointed at that model. Undefined outside Forge.
 */
export function useForgeAiModelMenu(): readonly ContextMenuItem[] | undefined {
  const [models, setModels] = useState<ForgeModel[]>([]);

  useEffect(() => {
    if (!isForgeEmbedded()) {
      return;
    }
    const load = () => void fetchForgeModels().then(setModels);
    load();
    // Keys, downloads, and provider catalogs change in Forge while the canvas is open.
    window.addEventListener('focus', load);
    return () => window.removeEventListener('focus', load);
  }, []);

  return useMemo(() => {
    if (!isForgeEmbedded()) {
      return undefined;
    }

    const modelItem = (model: ForgeModel): ContextMenuItem => ({
      id: `add-ai-model:${model.id}`,
      label: model.name,
      data: { model: model.id, title: model.name },
      infoBox: {
        title: model.name,
        description: `Adds a ${model.provider} model block. Connect a prompt to its input and read the answer from its output.`,
      },
    });

    const providers = [...new Set(models.map((model) => model.provider))];

    return [
      {
        id: `add-ai-model:${forgeLoadedLocalModel}`,
        label: 'Loaded local model',
        data: { model: forgeLoadedLocalModel, title: 'Local Model' },
        infoBox: {
          title: 'Loaded local model',
          description: 'Uses whichever model is currently loaded in Forge. Nothing leaves this Mac.',
        },
      },
      ...providers.map(
        (provider): ContextMenuItem => ({
          id: `add-ai-model-provider:${provider}`,
          label: provider,
          items: models.filter((model) => model.provider === provider).map(modelItem),
        }),
      ),
    ];
  }, [models]);
}
