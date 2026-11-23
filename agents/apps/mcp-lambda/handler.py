"""An MCP tool backend as a Lambda, invoked by AgentCore Gateway.

The gateway owns the MCP protocol: it advertises the tool catalogue, accepts tools/list and
tools/call from the agent, and invokes this function for one tool at a time. So there is no JSON-RPC
here, no transport and no auth of its own -- the gateway signs the invoke with its own role, and the
agent's identity was already verified at the gateway's door.

The event carries the tool name in the context and the arguments in the body.
"""
import datetime
import json

ORDERS = {
    "ORD-12345": {"status": "in transit", "items": ["laptop"], "eta": "2026-11-09"},
    "ORD-11111": {"status": "delivered", "items": ["headphones"], "eta": "2026-11-02"},
}


def _tool_name(event, context):
    # The gateway puts the resolved tool name in the client context; fall back to the event for
    # a direct invoke during testing.
    try:
        cc = context.client_context.custom
        for key in ("bedrockAgentCoreToolName", "bedrockagentcoreToolName", "toolName"):
            if key in cc:
                return cc[key].split("___")[-1]
    except Exception:
        pass
    return event.get("toolName") or event.get("name") or ""


def handler(event, context):
    name = _tool_name(event, context)
    args = event if isinstance(event, dict) else {}

    if name == "lookup_order":
        order_id = str(args.get("order_id", "")).strip()
        if order_id in ORDERS:
            return {"order_id": order_id, **ORDERS[order_id]}
        return {"error": f"no order {order_id!r}", "known": sorted(ORDERS)}

    if name == "get_time":
        return {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}

    return {"error": f"unknown tool {name!r}", "received_event": json.dumps(args)[:200]}
