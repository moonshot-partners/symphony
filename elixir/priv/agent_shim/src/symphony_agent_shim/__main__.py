from symphony_agent_shim import tracing

# Initialize Langfuse tracing BEFORE importing the server module, which pulls in
# claude_agent_sdk. The OpenInference instrumentor patches claude_agent_sdk on
# instrument(); running setup() first guarantees the patch is in place before
# the SDK is bound into any module namespace. No-op when LANGFUSE_* is unset.
tracing.setup()

from symphony_agent_shim.server import run  # noqa: E402 — must follow tracing.setup()

if __name__ == "__main__":
    run()
