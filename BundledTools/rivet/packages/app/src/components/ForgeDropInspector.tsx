import { css } from '@emotion/react';
import Button from '@atlaskit/button';
import { useEffect, useRef, useState } from 'react';
import { useAtomValue } from 'jotai';
import { useAiGraphBuilder } from '../hooks/useAiGraphBuilder';
import { modelSelectorOptions } from '../utils/modelSelectorOptions';
import { swallowPromise } from '../utils/syncWrapper';
import { canvasAiHotState } from '../state/ai';
import { loadForgeMCPTools } from '../prompts/forgeGraphArchitect';

type DroppedFile = {
  path: string;
  name: string;
  isDirectory: boolean;
  content?: string;
  contentTruncated?: boolean;
};

type DropAction = 'trace' | 'action' | 'expand' | 'ocr' | 'custom';

const styles = css`
  position: fixed;
  inset: 0;
  z-index: 600;
  display: grid;
  place-items: center;
  background: rgba(5, 7, 12, 0.62);
  backdrop-filter: blur(5px);

  .drop-card {
    width: min(680px, calc(100vw - 48px));
    padding: 20px;
    border: 1px solid var(--grey-dark);
    border-radius: 12px;
    background: var(--grey-darker);
    box-shadow: 0 24px 80px rgba(0, 0, 0, 0.55);
  }

  .drop-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 16px;
    margin-bottom: 6px;
  }

  .close-button {
    flex: none;
  }

  h2 {
    margin: 0 0 6px;
    font-size: 20px;
  }

  p {
    margin: 0 0 14px;
    color: var(--grey-light);
  }

  .files {
    max-height: 180px;
    overflow: auto;
    margin: 0 0 16px;
    padding: 10px 12px;
    border-radius: 8px;
    background: rgba(0, 0, 0, 0.24);
    font: 12px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace;
  }

  .actions {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
  }

  .instruction {
    width: 100%;
    min-height: 82px;
    box-sizing: border-box;
    margin: 0 0 10px;
    padding: 10px 12px;
    resize: vertical;
    border: 1px solid var(--grey-dark);
    border-radius: 8px;
    background: rgba(0, 0, 0, 0.24);
    color: var(--grey-lightest);
    font: inherit;
  }

  .output-options {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 0 0 14px;
    color: var(--grey-light);
    font-size: 12px;

    select {
      border: 1px solid var(--grey-dark);
      border-radius: 6px;
      background: var(--grey-darker);
      color: var(--grey-lightest);
      padding: 4px 7px;
    }
  }

  .feedback {
    min-height: 18px;
    margin-top: 14px;
    color: var(--grey-light);
    font-size: 12px;
  }

  .drop-advice {
    margin: 0 0 16px;
    padding: 12px;
    border-left: 3px solid var(--primary);
    border-radius: 4px;
    background: rgba(0, 0, 0, 0.2);
    color: var(--grey-lightest);
    white-space: pre-wrap;
  }

  &.manual-shelf {
    inset: auto 18px 18px auto;
    display: block;
    width: min(460px, calc(100vw - 36px));
    padding: 14px;
    border: 1px solid var(--grey-dark);
    border-radius: 10px;
    background: var(--grey-darker);
    box-shadow: 0 16px 50px rgba(0, 0, 0, 0.45);

    .actions {
      margin-top: 10px;
    }
  }
`;

function requestFor(
  action: DropAction,
  files: DroppedFile[],
  instruction: string,
  structuredOutput: boolean,
  outputFormat: string,
): string {
  const paths = files.map((file) => `- ${file.path}${file.isDirectory ? ' (directory)' : ''}`).join('\n');
  const inlineSources = files
    .filter((file) => file.content !== undefined)
    .map(
      (file) =>
        `\nSOURCE ${file.name}${file.contentTruncated ? ' (truncated)' : ''}\n${file.content ?? ''}\nEND SOURCE ${file.name}`,
    )
    .join('\n');
  const userDirection = instruction.trim()
    ? `\n\nThe user's direct build instruction is authoritative:\n${instruction.trim()}`
    : '';
  const outputDirection = structuredOutput
    ? `\n\nThe user wants a structured ${outputFormat} output. Add an explicit schema/validation step and a save/export step for that output; do not merely mention formatting in a note.`
    : '\n\nDo not add a structured-output layer unless the source or workflow actually requires one.';
  const shared = `\nThe user dropped these local sources onto the Forge graph:\n${paths}\n${inlineSources}\n\nUse Desktop Commander MCP to read sources that have real disk paths. When inline source content is supplied, inspect it directly and use Desktop Commander to resolve reachable dependencies when possible. Cite file paths and symbols in node titles or notes. Preserve calls whose targets are not yet available as explicit unresolved dependency nodes; do not invent their behavior. Build and show changes incrementally.${userDirection}${outputDirection}`;

  if (action === 'action') {
    return `Add the dropped source as executable workflow action nodes. Detect the real runtime from its content and extension (Python, shell, Swift, or another supported action), preserve arguments, environment, working directory, inputs, outputs, and error behavior, and connect only relationships established by the source.${shared}`;
  }
  if (action === 'expand') {
    return `Expand the current workflow using the dropped source. Reconcile it with existing nodes, resolve matching unresolved dependencies in place, trace imports, subprocesses, MCP calls, model calls, database/file/network boundaries, and add only newly established behavior.${shared}`;
  }
  if (action === 'ocr') {
    return `Add a real OCR action for the dropped image or document. Inspect the machine for an existing Apple Vision OCR implementation or installed OCR executable before designing the node; prefer native Apple Vision when available, preserve recognized text, confidence, page/frame identity, and bounding boxes when the engine exposes them, and make the engine configurable. Connect the dropped artifact as input and extracted text/structured detections as output. Do not label the action runnable until its actual engine invocation and ports are configured.${shared}`;
  }
  if (action === 'custom') {
    return `Execute the user's graph-building instruction over the dropped source. The instruction may create, edit, connect, disconnect, configure, trace, or remove any workflow nodes the graph runtime supports. Infer only low-risk mechanical details; when a material choice is missing, expose the choice as a configurable node value or ask one terse, specific question. Do not reduce the request to analysis or advice—make the graph changes.${shared}`;
  }
  return `Trace and graph the dropped source as a living code map. Follow its entry points, imports, function and script calls, branches, loops, retries, concurrency, side effects, data flow, prompts, external services, MCP servers, and produced artifacts. Flag concrete bug risks or broken references as findings without changing the source.${shared}`;
}

export function ForgeDropInspector() {
  const [files, setFiles] = useState<DroppedFile[]>([]);
  const [running, setRunning] = useState(false);
  const [feedback, setFeedback] = useState('');
  const [reviewingManualDrop, setReviewingManualDrop] = useState(false);
  const [dropAdvice, setDropAdvice] = useState('');
  const [adviceLoading, setAdviceLoading] = useState(false);
  const [instruction, setInstruction] = useState('');
  const [structuredOutput, setStructuredOutput] = useState(false);
  const [outputFormat, setOutputFormat] = useState('JSON Schema');
  const adviceAbortController = useRef<AbortController | null>(null);
  const buildAbortController = useRef<AbortController | null>(null);
  const canvasAiHot = useAtomValue(canvasAiHotState);
  const hasVisualDocument = files.some((file) => /\.(pdf|png|jpe?g|heic|heif|tiff?|bmp|gif)$/i.test(file.name));
  const buildGraph = useAiGraphBuilder({ record: false, onFeedback: setFeedback });

  useEffect(() => {
    if (!canvasAiHot || files.length === 0) {
      setAdviceLoading(false);
      return;
    }

    const abortController = new AbortController();
    adviceAbortController.current = abortController;
    setAdviceLoading(true);
    setDropAdvice('');

    const inspectDrop = async () => {
      const tools = await loadForgeMCPTools().catch(() => []);
      const previews: string[] = [];

      for (const file of files) {
        if (file.content !== undefined) {
          previews.push(`${file.name}:\n${file.content.slice(0, 40_000)}`);
          continue;
        }
        if (file.path.includes('(direct drop;')) continue;

        const toolName = file.isDirectory ? 'list_directory' : 'read_file';
        const tool = tools.find((candidate) => candidate.name === toolName);
        if (!tool) continue;
        try {
          const response = await fetch(`${globalThis.location.origin}/v1/forge/mcp/call`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              server: tool.server,
              tool: tool.name,
              arguments: file.isDirectory ? { path: file.path, depth: 2 } : { path: file.path },
            }),
            signal: abortController.signal,
          });
          if (response.ok) {
            previews.push(`${file.name}:\n${(await response.text()).slice(0, 40_000)}`);
          }
        } catch {
          // The Canvas AI can still classify the source from its path and extension.
        }
      }

      const response = await fetch(`${globalThis.location.origin}/v1/chat/completions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: 'forge/local',
          stream: false,
          temperature: 0.2,
          max_tokens: 320,
          messages: [
            {
              role: 'system',
              content:
                'You are Forge Canvas Operator, a coding and workflow-building model, not a conversational chatbot. Inspect only the supplied evidence. Never greet, praise, speculate, offer opinions, or ask broad questions. Never invent missing behavior. Respond in at most 90 words using exactly these headings: TYPE, DOES, CONNECTIONS, NEXT. Under NEXT give terse executable choices such as TRACE, ADD ACTION, CONNECT, EXPAND, OCR, or NOTHING. A user may also issue any direct build instruction; the choices are shortcuts, not restrictions.',
            },
            {
              role: 'user',
              content: `Dropped sources:\n${files.map((file) => file.path).join('\n')}\n\nAvailable preview:\n${previews.join('\n\n').slice(0, 100_000)}`,
            },
          ],
        }),
        signal: abortController.signal,
      });

      if (!response.ok) {
        if (response.status === 409) {
          setDropAdvice('Load a local model to make Canvas AI hot. You can still choose an action below.');
          return;
        }
        throw new Error(`Canvas AI inspection failed (${response.status})`);
      }

      const payload = (await response.json()) as { choices?: Array<{ message?: { content?: string } }> };
      setDropAdvice(payload.choices?.[0]?.message?.content?.trim() || 'What would you like to do with this source?');
    };

    void inspectDrop()
      .catch((error) => {
        if (!abortController.signal.aborted) {
          setDropAdvice(error instanceof Error ? error.message : 'Canvas AI could not inspect this drop.');
        }
      })
      .finally(() => {
        if (!abortController.signal.aborted) setAdviceLoading(false);
      });

    return () => {
      abortController.abort();
      if (adviceAbortController.current === abortController) adviceAbortController.current = null;
    };
  }, [canvasAiHot, files]);

  useEffect(() => {
    if (files.length === 0) return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      event.preventDefault();
      closeInspector();
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [files.length]);

  useEffect(() => {
    const handleDrop = (event: Event) => {
      const detail = (event as CustomEvent<unknown>).detail;
      if (!Array.isArray(detail)) return;
      const dropped = detail.filter(
        (item): item is DroppedFile =>
          typeof item === 'object' &&
          item !== null &&
          typeof (item as DroppedFile).path === 'string' &&
          typeof (item as DroppedFile).name === 'string' &&
          typeof (item as DroppedFile).isDirectory === 'boolean',
      );
      if (dropped.length > 0) {
        setFiles(dropped);
        setReviewingManualDrop(false);
        setFeedback('Ready for the loaded local model to inspect through Desktop Commander.');
      }
    };
    const handleBrowserDrop = async (event: Event) => {
      const detail = (event as CustomEvent<unknown>).detail;
      if (!Array.isArray(detail)) return;
      const browserFiles = detail.filter((item): item is File => item instanceof File);
      if (browserFiles.length === 0) return;

      let remainingCharacters = 240_000;
      const dropped: DroppedFile[] = [];
      for (const file of browserFiles) {
        const textLike = /\.(py|sh|bash|zsh|swift|js|jsx|ts|tsx|jsonl?|csv|tsv|ya?ml|toml|md|txt|jinja2?|sql|cypher|cql|graphql|xml|html|css|rs|go|java|kt|rb|php|r)$/i.test(file.name);
        let content: string | undefined;
        let contentTruncated = false;
        if (textLike && remainingCharacters > 0) {
          const complete = await file.text();
          const allowed = Math.min(120_000, remainingCharacters);
          content = complete.slice(0, allowed);
          contentTruncated = complete.length > content.length;
          remainingCharacters -= content.length;
        }
        dropped.push({
          path: `${file.name} (direct drop; original path unavailable)`,
          name: file.name,
          isDirectory: false,
          content,
          contentTruncated,
        });
      }
      setFiles(dropped);
      setReviewingManualDrop(false);
      setFeedback('Drop received. Forge loaded readable source content directly.');
    };
    window.addEventListener('forge-files-dropped', handleDrop);
    window.addEventListener('forge-browser-files-dropped', handleBrowserDrop);
    return () => {
      window.removeEventListener('forge-files-dropped', handleDrop);
      window.removeEventListener('forge-browser-files-dropped', handleBrowserDrop);
    };
  }, []);

  async function run(action: DropAction) {
    const localModel = modelSelectorOptions[0];
    if (!localModel || files.length === 0) return;
    const abortController = new AbortController();
    buildAbortController.current = abortController;
    setRunning(true);
    setFeedback('Starting live inspection…');
    try {
      await buildGraph(
        requestFor(action, files, instruction, structuredOutput, outputFormat),
        localModel.value,
        abortController.signal,
      );
      setFiles([]);
      setFeedback('');
    } finally {
      if (buildAbortController.current === abortController) buildAbortController.current = null;
      setRunning(false);
    }
  }

  function closeInspector() {
    adviceAbortController.current?.abort();
    buildAbortController.current?.abort();
    adviceAbortController.current = null;
    buildAbortController.current = null;
    setRunning(false);
    setAdviceLoading(false);
    setReviewingManualDrop(false);
    setFiles([]);
    setFeedback('');
  }

  if (files.length === 0) return null;

  if (!canvasAiHot && !reviewingManualDrop) {
    return (
      <div css={styles} className="manual-shelf" role="status">
        <strong>{files.length === 1 ? `${files[0]!.name} staged` : `${files.length} sources staged`}</strong>
        <p>Canvas AI is Manual. No model request has been sent.</p>
        <div className="actions">
          <Button appearance="primary" onClick={() => setReviewingManualDrop(true)}>
            Ask Model…
          </Button>
          <Button appearance="subtle" onClick={closeInspector}>
            Close
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div css={styles} role="dialog" aria-modal="true" aria-label="Graph dropped files">
      <div className="drop-card">
        <div className="drop-header">
          <h2>{files.length === 1 ? `Map ${files[0]!.name}` : `Map ${files.length} dropped items`}</h2>
          <Button className="close-button" appearance="subtle" onClick={closeInspector}>
            Close
          </Button>
        </div>
        <p>Forge has the real disk paths. Choose how the live model should integrate them into this graph.</p>
        <div className="drop-advice">{adviceLoading ? 'Canvas AI is inspecting the drop…' : dropAdvice}</div>
        <div className="files">
          {files.map((file) => (
            <div key={file.path}>{file.isDirectory ? 'DIR ' : 'FILE'} {file.path}</div>
          ))}
        </div>
        <textarea
          className="instruction"
          value={instruction}
          onChange={(event) => setInstruction(event.target.value)}
          placeholder="Tell Forge what to build: connect this script to an AI model, validate its JSON output, then save it…"
          aria-label="Graph-building instruction"
        />
        <div className="output-options">
          <label>
            <input
              type="checkbox"
              checked={structuredOutput}
              onChange={(event) => setStructuredOutput(event.target.checked)}
            />{' '}
            Structured output
          </label>
          {structuredOutput && (
            <select value={outputFormat} onChange={(event) => setOutputFormat(event.target.value)}>
              <option>JSON Schema</option>
              <option>JSONL</option>
              <option>CSV</option>
              <option>YAML</option>
            </select>
          )}
        </div>
        <div className="actions">
          {(running || adviceLoading) && (
            <Button appearance="danger" onClick={closeInspector}>
              Stop &amp; Close
            </Button>
          )}
          <Button
            appearance="primary"
            isDisabled={running || instruction.trim().length === 0}
            onClick={() => swallowPromise(run('custom'))}
          >
            Build Instruction
          </Button>
          <Button isDisabled={running} onClick={() => swallowPromise(run('trace'))}>
            Trace &amp; Graph
          </Button>
          <Button isDisabled={running} onClick={() => swallowPromise(run('action'))}>
            Add as Action
          </Button>
          <Button isDisabled={running} onClick={() => swallowPromise(run('expand'))}>
            Expand Dependencies
          </Button>
          {hasVisualDocument && (
            <Button isDisabled={running} onClick={() => swallowPromise(run('ocr'))}>
              Extract Text (OCR)
            </Button>
          )}
          <Button
            appearance="subtle"
            onClick={() => (canvasAiHot ? closeInspector() : setReviewingManualDrop(false))}
          >
            Not Now
          </Button>
        </div>
        <div className="feedback">{running ? feedback || 'Inspecting…' : feedback}</div>
      </div>
    </div>
  );
}
