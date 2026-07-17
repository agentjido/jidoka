# Use Case 18: Multimodal, Voice, and Realtime Agents

**Roadmap status:** Product gap.

## Comparison contract

An agent accepts typed image/audio/video/document content and, when realtime is
claimed, maintains a low-latency bidirectional session with streamed audio,
interruptions, tools, approvals, handoffs, history, and traceable lifecycle
events.

Atomic features: `A09` multimodal content and `R06` realtime voice runtime.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Multimodal surface | Realtime boundary |
| --- | --- | --- |
| Mastra | Agent/provider messages plus voice integrations for TTS, STT, speech-to-speech, realtime tools, multiple providers, and LiveKit. | Voice is an official integration family and provider behavior varies. |
| LangChain | Standard cross-provider text/image/audio/video blocks and model integrations. | Official voice guidance composes STT → agent → TTS or provider live models; no single provider-neutral core voice runtime. |
| Pydantic AI | Images, audio, video, documents, uploads, binary/URL content. | No bidirectional realtime/telephony/interruption runtime was established. |
| OpenAI Agents SDK | Rich input items plus a voice pipeline and realtime WebSocket/SIP sessions with text/audio, interruptions, tools, approvals, handoffs, guardrails, and history. | Python supports server-side WebSocket/SIP, not browser WebRTC; model transport is hosted. |
| Google ADK | Multimodal content and Gemini Live bidirectional text/audio/video tooling. | Realtime is provider-specific rather than model-neutral and language support varies. |
| LlamaIndex | Agent inputs support text/images and the wider data stack handles rich documents/media. | No native live voice session runtime was established. |
| AutoGen | `MultiModalMessage` supports text/images; video/audio tooling exists in extensions. | No native bidirectional realtime voice agent runtime was established. |
| Jidoka | Current public agent messages/results and ReqLLM decision path are text/tool oriented. | No stable multimodal message contract, audio events, realtime session, interruption/playback tracking, STT/TTS pipeline, telephony, or voice handoff surface. |

## Roadmap decision

Decide whether Jidoka should remain transport-agnostic and accept multimodal
content through a future ReqLLM/Jido contract, or own a realtime runtime. Voice
should not be represented as ordinary token streaming: interruption, playback,
session history, tool approval, and audio tracing are separate semantics.

## Official sources

- [Mastra voice](https://mastra.ai/docs/voice/overview)
- [LangChain messages](https://docs.langchain.com/oss/python/langchain/messages), [voice-agent guide](https://docs.langchain.com/oss/python/langchain/voice-agent)
- [Pydantic AI multimodal input](https://pydantic.dev/docs/ai/advanced-features/input/)
- [OpenAI realtime guide](https://openai.github.io/openai-agents-python/realtime/guide/), [voice quickstart](https://openai.github.io/openai-agents-python/voice/quickstart/)
- [Google ADK streaming](https://adk.dev/streaming/)
- [LlamaIndex agents](https://developers.llamaindex.ai/python/framework/module_guides/deploying/agents/)
- [AutoGen agents](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/agents.html)
