import { persistGatewayHeartbeat } from "@/lib/cloud/device-repository";
import { gatewayHeartbeatHandler } from "@/lib/cloud/gateway-heartbeat-persistence";

export const POST = gatewayHeartbeatHandler(persistGatewayHeartbeat);
