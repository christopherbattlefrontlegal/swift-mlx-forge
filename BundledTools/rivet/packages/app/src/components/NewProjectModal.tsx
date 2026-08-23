import { useState, type FC, type FormEvent } from 'react';
import { useAtomValue, useSetAtom } from 'jotai';
import { newProjectModalOpenState } from '../state/ui';
import Modal, { ModalTransition, ModalBody, ModalHeader, ModalTitle, ModalFooter } from '@atlaskit/modal-dialog';
import { ButtonItem, SideNavigation, Section } from '@atlaskit/side-navigation';
import { css } from '@emotion/react';
import { Field } from '@atlaskit/form';
import TextField from '@atlaskit/textfield';
import { match } from 'ts-pattern';
import Button from '@atlaskit/button';
import { useNewProject } from '../hooks/useNewProject';
import aiAgentTemplateProject from '../assets/templates/ai_agent_template.rivet-project?raw';
import mcpAiAgentTemplateProject from '../assets/templates/mcp_ai_agent_template.rivet-project?raw';
import { useNewProjectFromTemplate } from '../hooks/useNewProjectFromTemplate';

export const NewProjectModalRenderer: FC = () => {
  const newProjectModalOpen = useAtomValue(newProjectModalOpenState);

  return <ModalTransition>{newProjectModalOpen && <NewProjectModal />}</ModalTransition>;
};

const modalBody = css`
  min-height: 300px;
  display: grid;
  grid-template-columns: 240px 1fr;

  nav {
    padding-bottom: 20px;
  }

  main {
    padding: 0 30px 100px 30px;
  }

  .actions {
    display: flex;
    justify-content: flex-end;
    margin-top: 20px;
  }
`;

const buttonsContainer = css`
  > button span {
    // Fix invisible text on Ubuntu/Kubuntu
    overflow-x: visible !important;
  }
`;

export const NewProjectModal: FC = () => {
  const setNewProjectModalOpen = useSetAtom(newProjectModalOpenState);

  const [selectedTemplate, setSelectedTemplate] = useState<string>('blank_project');

  const onProjectCreated = () => {
    setNewProjectModalOpen(false);
  };

  return (
    <Modal onClose={() => setNewProjectModalOpen(false)} width="75%">
      <ModalHeader>
        <ModalTitle>New Forge Project</ModalTitle>
      </ModalHeader>
      <ModalBody>
        <div css={modalBody}>
          <nav>
            <SideNavigation label="Templates">
              <Section title="Empty Projects">
                <div css={buttonsContainer}>
                  <ButtonItem
                    isSelected={selectedTemplate === 'blank_project'}
                    onClick={() => setSelectedTemplate('blank_project')}
                  >
                    Blank Project
                  </ButtonItem>
                </div>
              </Section>
              <Section title="Templates">
                <ButtonItem
                  isSelected={selectedTemplate === 'ai_agent'}
                  onClick={() => setSelectedTemplate('ai_agent')}
                >
                  AI Agent Template
                </ButtonItem>
                <ButtonItem
                  isSelected={selectedTemplate === 'mcp_ai_agent'}
                  onClick={() => setSelectedTemplate('mcp_ai_agent')}
                >
                  MCP AI Agent Template
                </ButtonItem>
              </Section>
            </SideNavigation>
          </nav>
          <main>
            {match(selectedTemplate)
              .with('blank_project', () => <BlankProjectTemplate onCreated={onProjectCreated} />)
              .with('ai_agent', () => <AiAgentTemplate onCreated={onProjectCreated}/>)
              .with('mcp_ai_agent', () => <MCPAiAgentTemplate onCreated={onProjectCreated}/>)
              .with('community_templates', () => <div>Coming soon!</div>)
              .with('community_examples', () => <div>Coming soon!</div>)
              .otherwise((template) => (
                <div>Unknown template: {template}</div>
              ))}
          </main>
        </div>
      </ModalBody>
      <ModalFooter>
        <span />
      </ModalFooter>
    </Modal>
  );
};

const BlankProjectTemplate: FC<{
  onCreated: () => void;
}> = ({ onCreated }) => {
  const [projectName, setProjectName] = useState('');
  const newProject = useNewProject();

  const createProject = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    newProject({ title: projectName });
    onCreated();
  };

  return (
    <div className="template blank-project">
      <h1>Blank Project</h1>
      <p>
        Name it now if you want, or leave the name empty and Forge will assign Untitled automatically.
      </p>
      <form onSubmit={createProject}>
        <Field name="projectName" label="Name (optional)">
          {() => (
            <TextField
              name="projectName"
              value={projectName}
              onChange={(event) => setProjectName((event.target as HTMLInputElement).value)}
              placeholder="Untitled"
              autoComplete="off"
            />
          )}
        </Field>
        <div className="actions">
          <Button appearance="primary" type="submit">
            Create Project
          </Button>
        </div>
      </form>
    </div>
  );
};


const AiAgentTemplate: FC<{
  onCreated: () => void;
}> = ({ onCreated }) => {
  const newProjectFromTemplate = useNewProjectFromTemplate();

  const createProject = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    newProjectFromTemplate(aiAgentTemplateProject);
    onCreated();
  };

  return (
    <div className="template ai-agent">
      <h1>AI Agent Template</h1>
      <p>
        Creates a new project from the Forge AI Agent Template. The template constructs the basic flow for an AI Agent that can use tools to perform specified commands.
      </p>
      <p>Run the AI Agent by clicking &quot;Run Main&quot; or &quot;Run&quot; while on the &quot;* Run Command&quot; Graph.</p>
      <form onSubmit={createProject}>
        <Button appearance="primary" type="submit">
          Create Project
        </Button>
      </form>
    </div>
  );
};

const MCPAiAgentTemplate: FC<{
  onCreated: () => void;
}> = ({ onCreated }) => {
  const newProjectFromTemplate = useNewProjectFromTemplate();

  const createProject = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    newProjectFromTemplate(mcpAiAgentTemplateProject);
    onCreated();
  };

  return (
    <div className="template ai-agent">
      <h1>MCP AI Agent Template</h1>
      <p>
        Creates a new project from the Forge MCP AI Agent Template. The template constructs the basic flow for an AI Agent that can use tools from an MCP server to perform specified commands by calling the tools on the MCP server.
      </p>
      <p>Run the AI Agent by clicking &quot;Run Main&quot; or &quot;Run&quot; while on the &quot;* Run Command&quot; Graph.</p>
      <form onSubmit={createProject}>
        <Button appearance="primary" type="submit">
          Create Project
        </Button>
      </form>
    </div>
  );
};
