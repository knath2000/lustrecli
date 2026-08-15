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
  allowPornHubAuth: boolean;
  allowHomeWorkspace: boolean;
  allowLibrary: boolean;
}) => Promise<{ id: string; kind: "feed_sites"; payload: Record<string, unknown> } | { id: string; kind: "feed_page"; payload: { siteID: string; page: number; query?: string } } | { id: string; kind: "destinations_list"; payload: Record<string, unknown> } | { id: string; kind: "local_folder_status" | "local_folder_choose" | "local_folder_reset"; payload: { deliveryProtocol: "gateway-v1" } } | { id: string; kind: "gdrive_connect"; payload: { deliveryProtocol: "gateway-v1" } } | { id: string; kind: "gdrive_test"; payload: { profileID: string; deliveryProtocol: "gateway-v1" } } | { id: string; kind: "gdrive_folders" | "gdrive_create_folder" | "gdrive_select_folder"; payload: { profileID: string; path: string; deliveryProtocol: "gateway-v1" } } | { id: string; kind: "queue_url"; payload: { url: string; title?: string; destination: string; deliveryProtocol: "gateway-v1"; preferredQualityLabel?: string } } | { id: string; kind: "job_action"; payload: { jobID: string; action: "pause" | "resume" | "cancel" | "retry"; deliveryProtocol: "gateway-v1" } } | { id: string; kind: "pornhub_auth_status" | "pornhub_auth_login" | "pornhub_auth_cancel" | "pornhub_auth_logout"; payload: { deliveryProtocol: "gateway-v1" } } | { id: string; kind: "home_status"; payload: { deliveryProtocol: "gateway-v1" } } | { id: string; kind: "extract_preview"; payload: { urls: string[]; deliveryProtocol: "gateway-v1" } } | { id: string; kind: "feed_resolve"; payload: { url: string; deliveryProtocol: "gateway-v1" } } | { id: string; kind: "library_list"; payload: { page: number; deliveryProtocol: "gateway-v1" } } | { id: string; kind: "library_update"; payload: { itemID: string; tags: string[]; collection?: string; favorite?: boolean; deliveryProtocol: "gateway-v1" } } | { id: string; kind: "library_remove" | "library_verify"; payload: { itemID: string; deliveryProtocol: "gateway-v1" } } | null>;

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
        || (values.allowPornHubAuth !== undefined && typeof values.allowPornHubAuth !== "boolean")
        || (values.allowHomeWorkspace !== undefined && typeof values.allowHomeWorkspace !== "boolean")
        || (values.allowLibrary !== undefined && typeof values.allowLibrary !== "boolean")
      ) throw new DeviceContractError("invalid_request", "Invalid command request.");
      const command = await select({
        deviceID: values.deviceID,
        connectionID: values.connectionID,
        sequence: values.sequence as number,
        allowFeedPage: values.allowFeedPage === true,
        allowDestinationsList: values.allowDestinationsList === true,
        allowFeedQueue: values.allowFeedQueue === true,
        allowPornHubAuth: values.allowPornHubAuth === true,
        allowHomeWorkspace: values.allowHomeWorkspace === true,
        allowLibrary: values.allowLibrary === true,
      });
      if (command?.kind === "feed_page") command.payload = normalizeFeedPageCommand(command.payload);
      if (command?.kind === "destinations_list" && Object.keys(command.payload).length !== 0) throw new DeviceContractError("invalid_request", "Invalid destination command.");
      if ((command?.kind === "local_folder_status" || command?.kind === "local_folder_choose" || command?.kind === "local_folder_reset") && (Object.keys(command.payload).join(",") !== "deliveryProtocol" || command.payload.deliveryProtocol !== "gateway-v1")) throw new DeviceContractError("invalid_request", "Invalid local folder command.");
      if (command?.kind === "gdrive_connect" && (Object.keys(command.payload).join(",") !== "deliveryProtocol" || command.payload.deliveryProtocol !== "gateway-v1")) throw new DeviceContractError("invalid_request", "Invalid Google Drive command.");
      if (command?.kind === "gdrive_test" && (Object.keys(command.payload).sort().join(",") !== "deliveryProtocol,profileID" || command.payload.deliveryProtocol !== "gateway-v1" || !UUID_PATTERN.test(command.payload.profileID))) throw new DeviceContractError("invalid_request", "Invalid Google Drive command.");
      if ((command?.kind === "gdrive_folders" || command?.kind === "gdrive_create_folder" || command?.kind === "gdrive_select_folder") && (Object.keys(command.payload).sort().join(",") !== "deliveryProtocol,path,profileID" || command.payload.deliveryProtocol !== "gateway-v1" || !UUID_PATTERN.test(command.payload.profileID) || !command.payload.path.startsWith("/") || command.payload.path.length > 1_024)) throw new DeviceContractError("invalid_request", "Invalid Google Drive command.");
      if (command?.kind === "queue_url") {
        const keys = Object.keys(command.payload).sort().join(",");
        if (
          !["deliveryProtocol,destination,title,url", "deliveryProtocol,destination,preferredQualityLabel,title,url", "deliveryProtocol,destination,url", "deliveryProtocol,destination,preferredQualityLabel,url"].includes(keys) ||
          command.payload.deliveryProtocol !== "gateway-v1" ||
          (command.payload.title !== undefined && (typeof command.payload.title !== "string" || !command.payload.title.trim() || command.payload.title.length > 512)) ||
          (command.payload.preferredQualityLabel !== undefined && (typeof command.payload.preferredQualityLabel !== "string" || !command.payload.preferredQualityLabel.trim() || command.payload.preferredQualityLabel.length > 80))
        ) throw new DeviceContractError("invalid_request", "Invalid queue command.");
      }
      if (command?.kind === "job_action" && (
        Object.keys(command.payload).sort().join(",") !== "action,deliveryProtocol,jobID" ||
        command.payload.deliveryProtocol !== "gateway-v1" ||
        !UUID_PATTERN.test(command.payload.jobID) ||
        !["pause", "resume", "cancel", "retry"].includes(command.payload.action)
      )) throw new DeviceContractError("invalid_request", "Invalid job action command.");
      if (command?.kind === "pornhub_auth_status" || command?.kind === "pornhub_auth_login" || command?.kind === "pornhub_auth_cancel" || command?.kind === "pornhub_auth_logout") {
        if (Object.keys(command.payload).join(",") !== "deliveryProtocol" || command.payload.deliveryProtocol !== "gateway-v1") {
          throw new DeviceContractError("invalid_request", "Invalid PornHub auth command.");
        }
      }
      if (command?.kind === "home_status" && (Object.keys(command.payload).join(",") !== "deliveryProtocol" || command.payload.deliveryProtocol !== "gateway-v1")) throw new DeviceContractError("invalid_request", "Invalid Home status command.");
      if (command?.kind === "extract_preview" && (Object.keys(command.payload).sort().join(",") !== "deliveryProtocol,urls" || command.payload.deliveryProtocol !== "gateway-v1" || !Array.isArray(command.payload.urls) || command.payload.urls.length < 1 || command.payload.urls.length > 10)) throw new DeviceContractError("invalid_request", "Invalid extraction preview command.");
      if (command?.kind === "feed_resolve" && (Object.keys(command.payload).sort().join(",") !== "deliveryProtocol,url" || command.payload.deliveryProtocol !== "gateway-v1")) throw new DeviceContractError("invalid_request", "Invalid Feed extraction command.");
      if (command?.kind === "library_list" && (Object.keys(command.payload).sort().join(",") !== "deliveryProtocol,page" || command.payload.deliveryProtocol !== "gateway-v1" || !Number.isSafeInteger(command.payload.page) || command.payload.page < 1 || command.payload.page > 100)) throw new DeviceContractError("invalid_request", "Invalid Library command.");
      if ((command?.kind === "library_remove" || command?.kind === "library_verify") && (Object.keys(command.payload).sort().join(",") !== "deliveryProtocol,itemID" || command.payload.deliveryProtocol !== "gateway-v1" || !UUID_PATTERN.test(command.payload.itemID))) throw new DeviceContractError("invalid_request", "Invalid Library command.");
      if (command?.kind === "library_update" && (command.payload.deliveryProtocol !== "gateway-v1" || !UUID_PATTERN.test(command.payload.itemID) || !Array.isArray(command.payload.tags) || command.payload.tags.length > 20)) throw new DeviceContractError("invalid_request", "Invalid Library command.");
      return Response.json({ version: 1, type: "gateway-command-selected", sequence: values.sequence, correlationID: values.correlationID, command }, { headers: { "Cache-Control": "no-store" } });
    } catch (error) {
      if (error instanceof Error && error.message === "unauthenticated") return Response.json({ error: { code: "unauthenticated", message: "Unauthenticated." } }, { status: 401 });
      return Response.json(deviceError(error), { status: error instanceof DeviceContractError ? 400 : 500 });
    }
  };
}
