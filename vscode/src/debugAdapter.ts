import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import { spawn, ChildProcess } from 'child_process';
import {
    DebugSession, InitializedEvent, TerminatedEvent, StoppedEvent, OutputEvent
} from '@vscode/debugadapter';
import { DebugProtocol } from '@vscode/debugprotocol';

const outputChannel = vscode.window.createOutputChannel('Etch Debug Adapter');

function log(message: string) {
    const timestamp = new Date().toISOString();
    const logMessage = `[${timestamp}] ${message}`;
    outputChannel.appendLine(logMessage);
    console.log(`[Etch Debug Adapter] ${logMessage}`);
}

export class EtchDebugAdapterProvider implements vscode.DebugAdapterDescriptorFactory {

    createDebugAdapterDescriptor(
        session: vscode.DebugSession,
        executable: vscode.DebugAdapterExecutable | undefined
    ): vscode.ProviderResult<vscode.DebugAdapterDescriptor> {
        log('Creating inline debug adapter (not external executable)');
        log(`Session ID: ${session.id}, Type: ${session.type}, Name: ${session.name}`);
        log(`Session configuration: ${JSON.stringify(session.configuration, null, 2)}`);

        // Return an inline debug adapter - VS Code will create the debug session in-process
        return new vscode.DebugAdapterInlineImplementation(new EtchDebugAdapter());
    }
}

class EtchDebugAdapter extends DebugSession {
    private etchProcess: ChildProcess | undefined;
    private nextSeq = 1;
    private pendingStackTraceResponse: DebugProtocol.StackTraceResponse | undefined;

    constructor() {
        super();
        log('EtchDebugAdapter created');
        this.setDebuggerLinesStartAt1(true);
        this.setDebuggerColumnsStartAt1(true);
    }

    protected initializeRequest(response: DebugProtocol.InitializeResponse, args: DebugProtocol.InitializeRequestArguments): void {
        log('Handling initialize request - will be forwarded to Etch when process starts');

        // Store the capabilities that we support
        response.body = response.body || {};
        response.body.supportsConfigurationDoneRequest = true;
        response.body.supportsBreakpointLocationsRequest = false;
        response.body.supportsStepBack = false;
        response.body.supportsRestartFrame = false;
        response.body.supportsTerminateRequest = true;

        this.sendResponse(response);
        this.sendEvent(new InitializedEvent());
        log('Sent initialize response and initialized event');
    }


    protected launchRequest(response: DebugProtocol.LaunchResponse, args: DebugProtocol.LaunchRequestArguments): void {
        log('Handling launch request');

        const launchArgs = args as any;
        const program = launchArgs.program;
        const workspaceFolder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(program));
        const workspacePath = workspaceFolder?.uri.fsPath || vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;

        if (!workspacePath) {
            log('ERROR: No workspace folder found');
            this.sendErrorResponse(response, 2001, 'No workspace folder found');
            return;
        }

        const etchExecutablePath = path.join(workspacePath, 'etch');
        log(`Attempting to launch: ${etchExecutablePath} --debug-server ${program}`);

        try {
            // Spawn the Etch debug server process
            this.etchProcess = spawn(etchExecutablePath, ['--debug-server', program], {
                cwd: workspacePath,
                stdio: ['pipe', 'pipe', 'pipe']
            });

            log(`Etch process spawned with PID: ${this.etchProcess.pid}`);

            // Handle process events
            this.etchProcess.on('error', (error) => {
                log(`Etch process error: ${error.message}`);
                this.sendErrorResponse(response, 2002, `Failed to launch Etch: ${error.message}`);
            });

            this.etchProcess.on('exit', (code, signal) => {
                log(`Etch process exited with code ${code}, signal ${signal}`);
                this.sendEvent(new TerminatedEvent());
            });

            // Handle stdout - DAP messages from Etch debug server
            let stdoutBuffer = '';
            this.etchProcess.stdout?.on('data', (data) => {
                stdoutBuffer += data.toString();

                // Process complete JSON messages (one per line)
                const lines = stdoutBuffer.split('\n');
                stdoutBuffer = lines.pop() || ''; // Keep incomplete line in buffer

                for (const line of lines) {
                    if (line.trim()) {
                        try {
                            const message = JSON.parse(line.trim());
                            log(`Received from Etch: ${JSON.stringify(message, null, 2)}`);
                            this.handleEtchMessage(message);
                        } catch (e) {
                            log(`Failed to parse JSON from Etch: ${line.trim()}: ${e}`);
                        }
                    }
                }
            });

            // Handle stderr - debug output from Etch
            this.etchProcess.stderr?.on('data', (data) => {
                const output = data.toString();
                log(`Etch stderr: ${output.trim()}`);
            });

            // Send success response
            this.sendResponse(response);

            // Send initialize request to Etch debug server
            setTimeout(() => {
                this.sendToEtch('initialize', {});

                // Send launch request to Etch debug server
                setTimeout(() => {
                    this.sendToEtch('launch', { program: program });
                }, 100);
            }, 500); // Give Etch process time to start

        } catch (error) {
            log(`Failed to spawn Etch process: ${error}`);
            this.sendErrorResponse(response, 2003, `Failed to spawn Etch process: ${error}`);
        }
    }

    protected disconnectRequest(response: DebugProtocol.DisconnectResponse, args: DebugProtocol.DisconnectArguments): void {
        log('Handling disconnect request');

        if (this.etchProcess) {
            log('Terminating Etch process');
            this.etchProcess.kill();
            this.etchProcess = undefined;
        }

        this.sendResponse(response);
    }


    private handleEtchMessage(message: any): void {
        if (message.type === 'event') {
            log(`Forwarding event to VSCode: ${message.event}`);

            switch (message.event) {
                case 'stopped':
                    this.sendEvent(new StoppedEvent(
                        message.body.reason || 'pause',
                        message.body.threadId || 1
                    ));
                    break;

                case 'terminated':
                    this.sendEvent(new TerminatedEvent());
                    break;

                case 'output':
                    // Create an OutputEvent with the message body
                    this.sendEvent(new OutputEvent(message.body.output, message.body.category));
                    break;

                default:
                    // For other events, just log them
                    log(`Unhandled event type: ${message.event}`);
            }
        } else if (message.type === 'response') {
            log(`Received response from Etch: ${JSON.stringify(message)}`);

            // Handle specific response types
            if (message.command === 'stackTrace' && this.pendingStackTraceResponse) {
                // Forward stack trace response to VSCode
                log(`Stack trace response from Etch: ${JSON.stringify(message.body, null, 2)}`);
                this.pendingStackTraceResponse.body = message.body;
                this.sendResponse(this.pendingStackTraceResponse);
                this.pendingStackTraceResponse = undefined;
                log('Forwarded stack trace response to VSCode');
            }
        }
    }

    private sendToEtch(command: string, args?: any): void {
        if (!this.etchProcess) {
            log(`ERROR: Cannot send ${command} - Etch process not started`);
            return;
        }

        if (!this.etchProcess.stdin) {
            log(`ERROR: Cannot send ${command} - Etch stdin not available`);
            return;
        }

        const request = {
            seq: this.nextSeq++,
            type: 'request',
            command: command,
            arguments: args || {}
        };

        const message = JSON.stringify(request) + '\n';
        log(`Sending to Etch: ${message.trim()}`);
        this.etchProcess.stdin.write(message);
    }

    // Override debug protocol methods to forward to Etch
    protected setBreakPointsRequest(response: DebugProtocol.SetBreakpointsResponse, args: DebugProtocol.SetBreakpointsArguments): void {
        log('Setting breakpoints');
        this.sendToEtch('setBreakpoints', {
            path: args.source.path,
            lines: args.breakpoints?.map(bp => bp.line) || []
        });

        // Send immediate response for now - in a real implementation we'd wait for Etch's response
        response.body = {
            breakpoints: args.breakpoints?.map(bp => ({ verified: true, line: bp.line })) || []
        };
        this.sendResponse(response);
    }

    protected continueRequest(response: DebugProtocol.ContinueResponse, args: DebugProtocol.ContinueArguments): void {
        log('Continue request');
        this.sendToEtch('continue');
        this.sendResponse(response);
    }

    protected nextRequest(response: DebugProtocol.NextResponse, args: DebugProtocol.NextArguments): void {
        log('Next (step over) request');
        this.sendToEtch('next');
        this.sendResponse(response);
    }

    protected stepInRequest(response: DebugProtocol.StepInResponse, args: DebugProtocol.StepInArguments): void {
        log('Step in request');
        this.sendToEtch('stepIn');
        this.sendResponse(response);
    }

    protected stepOutRequest(response: DebugProtocol.StepOutResponse, args: DebugProtocol.StepOutArguments): void {
        log('Step out request');
        this.sendToEtch('stepOut');
        this.sendResponse(response);
    }

    protected pauseRequest(response: DebugProtocol.PauseResponse, args: DebugProtocol.PauseArguments): void {
        log('Pause request');
        this.sendToEtch('pause');
        this.sendResponse(response);
    }

    protected stackTraceRequest(response: DebugProtocol.StackTraceResponse, args: DebugProtocol.StackTraceArguments): void {
        log(`Stack trace request for thread ${args.threadId}, startFrame: ${args.startFrame}, levels: ${args.levels}`);

        // Store the response to send back when Etch responds
        this.pendingStackTraceResponse = response;

        // Forward to Etch debug server
        this.sendToEtch('stackTrace', {
            threadId: args.threadId,
            startFrame: args.startFrame || 0,
            levels: args.levels || 20
        });

        log('Stack trace request forwarded to Etch');

        // Add a timeout fallback in case Etch doesn't respond
        setTimeout(() => {
            if (this.pendingStackTraceResponse) {
                log('Stack trace response timeout - sending empty response');
                this.pendingStackTraceResponse.body = {
                    stackFrames: [],
                    totalFrames: 0
                };
                this.sendResponse(this.pendingStackTraceResponse);
                this.pendingStackTraceResponse = undefined;
            }
        }, 1000);
    }

    protected threadsRequest(response: DebugProtocol.ThreadsResponse): void {
        log('Threads request');
        response.body = {
            threads: [{ id: 1, name: 'Main Thread' }]
        };
        this.sendResponse(response);
    }

    protected configurationDoneRequest(response: DebugProtocol.ConfigurationDoneResponse, args: DebugProtocol.ConfigurationDoneArguments): void {
        log('Configuration done request');
        this.sendToEtch('configurationDone');
        this.sendResponse(response);
    }

    public shutdown(): void {
        log('Debug adapter shutdown called');
        if (this.etchProcess) {
            this.etchProcess.kill();
            this.etchProcess = undefined;
        }
        super.shutdown();
    }
}

