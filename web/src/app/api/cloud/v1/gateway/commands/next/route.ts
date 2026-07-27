import { nextGatewayCommand } from "@/lib/cloud/device-repository";
import { gatewayCommandHandler } from "@/lib/cloud/gateway-command-delivery";

export const POST = gatewayCommandHandler(nextGatewayCommand);
