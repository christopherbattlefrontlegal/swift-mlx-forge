import { useEffect } from 'react';
import { type MenuIds, useRunMenuCommand } from './useMenuCommands';

const forgeCommands = new Set<MenuIds>(['open_project', 'import_graph']);

export function useForgeNativeCommands() {
  const runMenuCommand = useRunMenuCommand();

  useEffect(() => {
    const handleCommand = (event: Event) => {
      const command = (event as CustomEvent<unknown>).detail;
      if (typeof command === 'string' && forgeCommands.has(command as MenuIds)) {
        runMenuCommand(command as MenuIds);
      }
    };

    window.addEventListener('forge-native-command', handleCommand);
    return () => window.removeEventListener('forge-native-command', handleCommand);
  }, [runMenuCommand]);
}
