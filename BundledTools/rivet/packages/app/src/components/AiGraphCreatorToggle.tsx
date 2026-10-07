import { css } from '@emotion/react';
import { type FC } from 'react';
import SparklesIcon from '../assets/icons/ai-sparks-solid.svg?react';
import { showAiGraphCreatorInputState } from './AiGraphCreatorInput';
import { useAtom, useAtomValue, useSetAtom } from 'jotai';
import { sidebarOpenState } from '../state/graphBuilder';
import { canvasAiHotState } from '../state/ai';
import clsx from 'clsx';

const styles = css`
  position: absolute;
  left: 16px;
  bottom: 16px;
  display: flex;
  align-items: center;
  gap: 8px;

  &.sidebar-open {
    left: 270px;
  }

  button {
    border: 1px solid var(--grey-dark);
    background: var(--grey-darker);
    cursor: pointer;
    color: var(--primary);

    &:hover {
      background: var(--grey-lightish);
      color: var(--grey-lightest);
    }
  }

  .creator-button {
    width: 48px;
    height: 48px;
    border-radius: 32px;
    z-index: 50;

    svg {
      width: 24px;
      height: 24px;
    }
  }

  .mode-button {
    height: 32px;
    padding: 0 11px;
    border-radius: 16px;
    color: var(--grey-light);
    font-size: 12px;

    &.hot {
      border-color: var(--primary);
      color: var(--primary);
    }
  }
`;

export const AiGraphCreatorToggle: FC = () => {
  const setShowAiGraphCreatorInput = useSetAtom(showAiGraphCreatorInputState);
  const isSidebarOpen = useAtomValue(sidebarOpenState);
  const [canvasAiHot, setCanvasAiHot] = useAtom(canvasAiHotState);

  const handleClick = () => {
    setShowAiGraphCreatorInput((prev) => !prev);
  };

  return (
    <div css={styles} className={clsx({ 'sidebar-open': isSidebarOpen })}>
      <button className="creator-button" onClick={handleClick} title="Ask the canvas AI">
        <SparklesIcon />
      </button>
      <button
        className={clsx('mode-button', { hot: canvasAiHot })}
        aria-pressed={canvasAiHot}
        onClick={() => setCanvasAiHot((value) => !value)}
        title="Hot opens model actions on drop; Manual stages sources without invoking the model"
      >
        Canvas AI: {canvasAiHot ? 'Hot' : 'Manual'}
      </button>
    </div>
  );
};
