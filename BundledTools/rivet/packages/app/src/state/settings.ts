import { atom } from 'jotai';
import { atomWithStorage } from 'jotai/utils';
import { type Settings } from '@ironclad/rivet-core';
import { isInTauri } from '../utils/tauri';
import { DEFAULT_CHAT_NODE_TIMEOUT } from '../../../core/src/utils/defaults';
import { createHybridStorage } from './storage.js';

// Legacy storage key for recoil-persist to avoid breaking existing users' settings
const { storage } = createHybridStorage('recoil-persist');

const isForgeEmbedded = globalThis.location?.pathname.startsWith('/rivet/') ?? false;
const forgeOpenAiEndpoint = isForgeEmbedded
  ? `${globalThis.location.origin}/v1/chat/completions`
  : '';

export const settingsState = atomWithStorage<Settings>(
  'settings',
  {
    recordingPlaybackLatency: 1000,

    openAiKey: isForgeEmbedded ? 'forge-local' : '',
    openAiOrganization: '',
    openAiEndpoint: forgeOpenAiEndpoint,
    chatNodeTimeout: DEFAULT_CHAT_NODE_TIMEOUT,

    pluginEnv: {},
    pluginSettings: {},
  },
  storage,
);

export const themes = [
  {
    label: 'Molten',
    value: 'molten',
  },
  {
    label: 'Grapefruit',
    value: 'grapefruit',
  },
  {
    label: 'Taffy',
    value: 'taffy',
  },
] as const;

export type Theme = (typeof themes)[number]['value'];

export const themeState = atomWithStorage<Theme>('theme', 'molten', storage);

export const recordExecutionsState = atomWithStorage<boolean>('recordExecutions', true, storage);

export const defaultExecutorState = atomWithStorage<'browser' | 'nodejs'>('defaultExecutor', 'browser', storage);

export const executorOptions = isInTauri()
  ? ([
      { label: 'Browser', value: 'browser' },
      { label: 'Node', value: 'nodejs' },
    ] as const)
  : ([{ label: 'Browser', value: 'browser' }] as const);

export const previousDataPerNodeToKeepState = atomWithStorage<number>('previousDataPerNodeToKeep', -1, storage);

export const preservePortTextCaseState = atomWithStorage<boolean>('preservePortTextCase', false, storage);

export const checkForUpdatesState = atomWithStorage<boolean>('checkForUpdates', true, storage);

export const skippedMaxVersionState = atomWithStorage<string | undefined>('skippedMaxVersion', undefined, storage);

export const updateModalOpenState = atom<boolean>(false);

export const updateStatusState = atom<string | undefined>(undefined);

export const zoomSensitivityState = atomWithStorage<number>('zoomSensitivity', 0.25, storage);

export const debuggerDefaultUrlState = atomWithStorage('debuggerDefaultUrl', 'ws://localhost:21888', storage);
