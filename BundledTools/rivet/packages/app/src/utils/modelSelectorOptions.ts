const standaloneModelSelectorOptions = [
  { label: 'Local Model', value: 'openai:local-model' },
  { label: 'OpenAI: GPT-4.1', value: 'openai:gpt-4.1' },
  { label: 'OpenAI: GPT-4.1 Mini', value: 'openai:gpt-4.1-mini' },
  { label: 'OpenAI: o4-mini', value: 'openai:o4-mini' },
  { label: 'Anthropic: Claude Sonnet 4', value: 'anthropic:claude-sonnet-4-20250514' },
  { label: 'Anthropic: Claude Opus 4', value: 'anthropic:claude-opus-4-20250514' },
  { label: 'Anthropic: Claude 3.7 Sonnet', value: 'anthropic:claude-3-7-sonnet-latest' },
] as const;

const forgeModelSelectorOptions = [{ label: 'Loaded Local Model', value: 'openai:forge/local' }] as const;

export const modelSelectorOptions = globalThis.location?.pathname.startsWith('/rivet/')
  ? forgeModelSelectorOptions
  : standaloneModelSelectorOptions;

export type ModelSelectorValue = (typeof modelSelectorOptions)[number]['value'];

export const defaultModelSelectorOption = modelSelectorOptions[0];

export const defaultModelSelectorValue = defaultModelSelectorOption.value;
