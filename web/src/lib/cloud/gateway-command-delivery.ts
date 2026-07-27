import { DeviceContractError, deviceError, normalizeFeedPageCommand } from "./device-contract.ts";

const MAX_COMMAND_REQUEST_BYTES = 4_096;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type SelectGatewayCommand = (input: {
  deviceID: string;
  connectionID: string;
  sequence: number;
  allowFeedPage: boolean;
  allowDestinationsList: boolean;
  allowFeedQueue: boolean;
}) => Promise<{ id: string; kind: "feed_sites"; payload: Record<string, unknown> } | { id: string; kind: "feed_page"; payload: { siteID: string; page: number; query?: string } } | { id: string; kind: "destinations_list"; payload: Record<string, unknown> } | { id: string; kind: "queue_url"; payload: { url: string; destination: string; deliveryProtocol: "gateway-v1" } } | null>;

export function gatewayCommandHandler(select: SelectGatewayCommand) {
  return async (request: Request) => {
    try {
      const secret = process.env.LUSTRE_GATEWAY_RELAY_SECRET;
      if (!secret || request.headers.get("X-Lustre-Gateway-Relay-Secret") !== secret) throw new Error("unauthenticated");
      const declaredSize = Number(request.headers.get("content-length") ?? "0");
      if (!Number.isFinite(declaredSize) || declaredSize < 0 || declaredSize > MAX_COMMAND_REQUEST_BYTES) throw new DeviceContractError("invalid_request", "Request body is too large.");
      const bytes = await request.arrayBuffer();
      if (bytes.byteLength > MAX_COMMAND_REQUEST_BYTES) throw new DeviceContractError("invalid_request", "Request body is too large.");
      let body: unknown;
      try { body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
      catch { throw new DeviceContractError("invalid_request", "Invalid command request."); }
      if (!body || typeof body !== "object" || Array.isArray(body)) throw new DeviceContractError("invalid_request", "Invalid command request.");
      const values = body as Record<string, unknown>;
      if (
        typeof values.deviceID !== "string" || !UUID_PATTERN.test(values.deviceID) ||
        typeof values.connectionID !== "string" || !UUID_PATTERN.test(values.connectionID) ||
        !Number.isSafeInteger(values.sequence) || (values.sequence as number) < 1 ||
        typeof values.correlationID !== "string" || values.correlationID.length < 1 || values.correlationID.length > 64 ||
        (values.allowFeedPage !== undefined && typeof values.allowFeedPage !== "boolean") ||
        (values.allowDestinationsList !== undefined && typeof values.allowDestinationsList !== "boolean")
        || (values.allowFeedQueue !== undefined && typeof values.allowFeedQueue !== "boolean")
      ) throw new DeviceContractError("invalid_request", "Invalid command request.");
      const command = await select({
        deviceID: values.deviceID,
        connectionID: values.connectionID,
        sequence: values.sequence as number,
        allowFeedPage: values.allowFeedPage === true,
        allowDestinationsList: values.allowDestinationsList === true,
        allowFeedQueue: values.allowFeedQueue === true,
      });
      if (command?.kind === "feed_page") command.payload = normalizeFeedPageCommand(command.payload);
      if (command?.kind === "destinations_list" && Object.keys(command.payload).length !== 0) throw new DeviceContractError("invalid_request", "Invalid destination command.");
      if (command?.kind === "queue_url" && (Object.keys(command.payload).sort().join(",") !== "deliveryProtocol,destination,url" || command.payload.deliveryProtocol !== "gateway-v1")) throw new DeviceContractError("invalid_request", "Invalid Feed queue command.");
      return Response.json({ version: 1, type: "gateway-command-selected", sequence: values.sequence, correlationID: values.correlationID, command }, { headers: { "Cache-Control": "no-store" } });
    } catch (error) {
      if (error instanceof Error && error.message === "unauthenticated") return Response.json({ error: { code: "unauthenticated", message: "Unauthenticated." } }, { status: 401 });
      return Response.json(deviceError(error), { status: error instanceof DeviceContractError ? 400 : 500 });
    }
  };
}
