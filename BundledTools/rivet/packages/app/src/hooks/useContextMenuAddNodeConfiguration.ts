import { type BuiltInNodeType, type NodeUIData, getError, globalRivetNodeRegistry } from '@ironclad/rivet-core';
import { type ContextMenuItem } from './useContextMenuConfiguration';
import { useMemo, useState } from 'react';
import { useBuiltInNodeImages } from './useBuiltInNodeImages';
import { useDependsOnPlugins } from './useDependsOnPlugins';
import { useGetRivetUIContext } from './useGetRivetUIContext';
import useAsyncEffect from 'use-async-effect';
import { toast } from 'react-toastify';
import { isNotNull } from '../utils/genericUtilFunctions';
import { orderBy, uniqBy } from 'lodash-es';
import { useAtomValue } from 'jotai';
import { nodeConstructorsState } from '../state/graph';
import { referencedProjectsState } from '../state/savedGraphs';

export const addContextMenuGroups = [
  {
    id: 'add-node-group:common',
    label: 'Common',
    infoBox: { title: 'Common', description: 'The blocks most flows start with: text, AI chat, and graph inputs and outputs.' },
  },
  {
    id: 'add-node-group:text',
    label: 'Text',
    infoBox: { title: 'Text', description: 'Write, combine, split, and search text — prompts, templates, and extraction.' },
  },
  {
    id: 'add-node-group:ai',
    label: 'AI',
    infoBox: { title: 'AI', description: 'Blocks that call a model or shape what goes into one.' },
  },
  {
    id: 'add-node-group:lists',
    label: 'Lists',
    infoBox: { title: 'Lists', description: 'Work with many items at once: filter, join, slice, shuffle.' },
  },
  {
    id: 'add-node-group:numbers',
    label: 'Numbers',
    infoBox: { title: 'Numbers', description: 'Math, comparisons, and random numbers.' },
  },
  {
    id: 'add-node-group:objects',
    label: 'Objects',
    infoBox: { title: 'Objects', description: 'Build and pick apart structured data (JSON).' },
  },
  {
    id: 'add-node-group:data',
    label: 'Data',
    infoBox: { title: 'Data', description: 'Read and write data sets, files, and saved values.' },
  },
  {
    id: 'add-node-group:logic',
    label: 'Logic',
    infoBox: { title: 'Logic', description: 'Make decisions: if/else, match, loops, and waiting.' },
  },
  {
    id: 'add-node-group:input-output',
    label: 'Input/Output',
    infoBox: { title: 'Input/Output', description: 'Bring things in and send things out: files, web requests, user questions.' },
  },
  {
    id: 'add-node-group:convenience',
    label: 'Convenience',
    infoBox: { title: 'Convenience', description: 'Shortcuts that bundle several steps into one block.' },
  },
  {
    id: 'add-node-group:advanced',
    label: 'Advanced',
    infoBox: { title: 'Advanced', description: 'Code, subgraphs, and other power tools.' },
  },
  {
    id: 'add-node-group:custom',
    label: 'Custom',
    infoBox: { title: 'Custom', description: 'Blocks added by your own code.' },
  },
  {
    id: 'add-node-group:mcp',
    label: 'MCP',
    infoBox: { title: 'MCP', description: 'Tools from the servers connected in Forge — Gmail, files, search, and more.' },
  },
] as const satisfies readonly ContextMenuItem[] & {
  items?: readonly ContextMenuItem[];
};

export function useContextMenuAddNodeConfiguration() {
  const referencedProjects = useAtomValue(referencedProjectsState);
  const constructors = useAtomValue(nodeConstructorsState);
  const builtInImages = useBuiltInNodeImages();
  const getUIContext = useGetRivetUIContext();

  const [nodeTypesWithUiData, setNodeTypesWithUiData] = useState<readonly { type: string; uiData: NodeUIData }[]>([]);

  useAsyncEffect(async () => {
    const context = await getUIContext({});

    let nodeTypesWithUiData = (
      await Promise.all(
        constructors.map(async (constructor) => {
          try {
            const { type } = constructor.create();

            const uiData = constructor.getUIData
              ? await constructor.getUIData(context)
              : ({
                  group: 'Custom',
                  contextMenuTitle: type,
                  infoBoxTitle: type,
                  infoBoxBody: '',
                } satisfies NodeUIData);

            return { type, uiData };
          } catch (err) {
            toast.error(`Error getting UI data for node type ${constructor.name}: ${getError(err).message}`);
            return undefined;
          }
        }),
      )
    ).filter(isNotNull);

    nodeTypesWithUiData = nodeTypesWithUiData.filter((x) => x.type !== 'referencedGraphAlias');

    for (const project of Object.values(referencedProjects)) {
      for (const graph of Object.values(project.graphs)) {
        const type: BuiltInNodeType = 'referencedGraphAlias';

        const uiData: NodeUIData = {
          group: 'Library',
          contextMenuTitle: graph.metadata?.name ?? 'Unknown Graph',
          infoBoxBody: graph.metadata?.description ?? 'Creates a node that references a graph from another project.',
          infoBoxTitle: graph.metadata?.name ?? 'Unknown Graph',
        };

        nodeTypesWithUiData.push({
          type: `${type}:${project.metadata!.id!}:${graph.metadata!.id!}`,
          uiData,
        });
      }
    }

    setNodeTypesWithUiData(nodeTypesWithUiData);
  }, [constructors, referencedProjects, getUIContext]);

  const plugins = useDependsOnPlugins();
  const groupsWithItems = useMemo(() => {
    const allGroups = uniqBy(
      [...addContextMenuGroups, ...plugins.flatMap((plugin) => plugin.contextMenuGroups ?? [])],
      (g) => g.id,
    );

    if (Object.values(referencedProjects).length > 0) {
      allGroups.push({
        id: 'add-node-group:references',
        label: 'Library',
      });
    }

    const groups = allGroups.map((group) => {
      let items = nodeTypesWithUiData
        .filter((item) =>
          Array.isArray(item.uiData.group)
            ? item.uiData.group.includes(group.label)
            : item.uiData.group === group.label,
        )
        .map((item): ContextMenuItem => {
          const { type } = item;

          return {
            id: `add-node:${type}`,
            label: item.uiData.contextMenuTitle ?? type,
            data: type,
            infoBox: {
              title: item.uiData.infoBoxTitle ?? type,
              description: item.uiData.infoBoxBody ?? '',
              image: builtInImages[type as keyof typeof builtInImages] ?? undefined,
            },
          };
        });

      items = orderBy(items, (item) => item.label);

      return { ...group, items };
    });

    return groups.filter((group) => group.items.length > 0);
  }, [builtInImages, nodeTypesWithUiData, plugins, referencedProjects]);

  return groupsWithItems;
}
