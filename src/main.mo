import Result "mo:base/Result";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Option "mo:base/Option";
import Nat "mo:base/Nat";
import Array "mo:base/Array";
import Int "mo:base/Int";
import Time "mo:base/Time";

import HttpTypes "mo:http-types";
import Map "mo:map/Map";
import Json "mo:json";

import AuthCleanup "mo:mcp-motoko-sdk/auth/Cleanup";
import AuthState "mo:mcp-motoko-sdk/auth/State";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";
import HttpAssets "mo:mcp-motoko-sdk/mcp/HttpAssets";
import Mcp "mo:mcp-motoko-sdk/mcp/Mcp";
import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import HttpHandler "mo:mcp-motoko-sdk/mcp/HttpHandler";
import Cleanup "mo:mcp-motoko-sdk/mcp/Cleanup";
import State "mo:mcp-motoko-sdk/mcp/State";
import Payments "mo:mcp-motoko-sdk/mcp/Payments";
import Beacon "mo:mcp-motoko-sdk/mcp/Beacon";
import ApiKey "mo:mcp-motoko-sdk/auth/ApiKey";

import SrvTypes "mo:mcp-motoko-sdk/server/Types";

import IC "mo:ic";

shared ({ caller = deployer }) persistent actor class McpServer(
  args : ?{
    owner : ?Principal;
  }
) = self {

  // The canister owner, who can manage treasury funds.
  var owner : Principal = Option.get(do ? { args!.owner! }, deployer);

  // State for certified HTTP assets (like /.well-known/...)
  var stable_http_assets : HttpAssets.StableEntries = [];
  transient let http_assets = HttpAssets.init(stable_http_assets);

  // =================================================================================
  // --- TASKPAD STATE ---
  // =================================================================================

  // Define the structure for a single task.
  public type Task = {
    id : Nat;
    description : Text;
    completed : Bool;
  };

  // Define the structure to hold all tasks and the next ID for a single user.
  public type UserTasks = {
    tasks : Map.Map<Nat, Task>;
    var next_id : Nat;
  };

  // The main state of our application. A map from a user's Principal
  // to their personal list of tasks.
  var task_data : Map.Map<Principal, UserTasks> = Map.new<Principal, UserTasks>();

  // The application context that holds our state for streams.
  var appContext : McpTypes.AppContext = State.init([]);

  // =================================================================================
  // --- AUTHENTICATION (ENABLED BY DEFAULT) ---
  // TaskPad is a personal application, so authentication is required to identify users.
  // =================================================================================

  let issuerUrl = "https://bfggx-7yaaa-aaaai-q32gq-cai.icp0.io";
  let allowanceUrl = "https://prometheusprotocol.org";
  let requiredScopes = ["openid"];

  public query func transformJwksResponse({
    context : Blob;
    response : IC.HttpRequestResult;
  }) : async IC.HttpRequestResult {
    { response with headers = [] };
  };

  transient let authContext : ?AuthTypes.AuthContext = ?AuthState.init(
    Principal.fromActor(self),
    owner,
    issuerUrl,
    requiredScopes,
    transformJwksResponse,
  );

  // =================================================================================
  // --- OPT-IN: USAGE ANALYTICS (BEACON) ---
  // =================================================================================

  // --- UNCOMMENT THIS BLOCK TO ENABLE THE BEACON ---
  let beaconCanisterId = Principal.fromText("m63pw-fqaaa-aaaai-q33pa-cai");
  transient let beaconContext : ?Beacon.BeaconContext = ?Beacon.init(
    beaconCanisterId, // Public beacon canister ID
    ?(15 * 60) // Send a beacon every 15 minutes
  );
  // --- END OF BEACON BLOCK ---

  // --- Timers ---
  Cleanup.startCleanupTimer<system>(appContext);

  // The AuthCleanup timer only needs to run if authentication is enabled.
  switch (authContext) {
    case (?ctx) { AuthCleanup.startCleanupTimer<system>(ctx) };
    case (null) { Debug.print("Authentication is disabled.") };
  };

  // The Beacon timer only needs to run if the beacon is enabled.
  switch (beaconContext) {
    case (?ctx) { Beacon.startTimer<system>(ctx) };
    case (null) { Debug.print("Beacon is disabled.") };
  };

  // --- 1. DEFINE YOUR TOOLS ---
  transient let tools : [McpTypes.Tool] = [
    {
      name = "add_task";
      title = ?"Add Task";
      description = ?"Creates a single new to-do item.";
      inputSchema = Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([("description", Json.obj([("type", Json.str("string")), ("description", Json.str("The content of the task."))]))])),
        ("required", Json.arr([Json.str("description")])),
      ]);
      outputSchema = ?Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([("id", Json.obj([("type", Json.str("number"))])), ("description", Json.obj([("type", Json.str("string"))])), ("completed", Json.obj([("type", Json.str("boolean"))]))])),
      ]);
      payment = null;
    },
    {
      name = "list_tasks";
      title = ?"List Tasks";
      description = ?"Retrieves all of your to-do items.";
      inputSchema = Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([])),
      ]);
      outputSchema = ?Json.obj([
        ("type", Json.str("object")), // The top-level type is now "object"
        ("properties", Json.obj([("tasks", Json.obj([("type", Json.str("array")), ("items", Json.obj([("type", Json.str("object")), ("properties", Json.obj([("id", Json.obj([("type", Json.str("number"))])), ("description", Json.obj([("type", Json.str("string"))])), ("completed", Json.obj([("type", Json.str("boolean"))]))]))]))]))])),
      ]);
      payment = null;
    },
    {
      name = "update_task_status";
      title = ?"Update Task Status";
      description = ?"Marks a task as complete or incomplete.";
      inputSchema = Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([("task_id", Json.obj([("type", Json.str("number"))])), ("completed", Json.obj([("type", Json.str("boolean"))]))])),
        ("required", Json.arr([Json.str("task_id"), Json.str("completed")])),
      ]);
      outputSchema = ?Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([("id", Json.obj([("type", Json.str("number"))])), ("description", Json.obj([("type", Json.str("string"))])), ("completed", Json.obj([("type", Json.str("boolean"))]))])),
      ]);
      payment = null;
    },
    {
      name = "delete_task";
      title = ?"Delete Task";
      description = ?"Permanently deletes a to-do item.";
      inputSchema = Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([("task_id", Json.obj([("type", Json.str("number"))]))])),
        ("required", Json.arr([Json.str("task_id")])),
      ]);
      outputSchema = ?Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([("status", Json.obj([("type", Json.str("string"))]))])),
      ]);
      payment = null;
    },
  ];

  // --- 2. DEFINE YOUR TOOL LOGIC ---

  // Helper to convert a Task object to a JSON object.
  private func _taskToJson(task : Task) : McpTypes.JsonValue {
    Json.obj([
      ("id", Json.int(task.id)),
      ("description", Json.str(task.description)),
      ("completed", Json.bool(task.completed)),
    ]);
  };

  private func _returnError(message : Text, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) {
    cb(#ok({ content = [#text({ text = message })]; isError = true; structuredContent = null }));
  };

  // Logic for adding a new task.
  func addTask(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) : async () {
    let caller = switch (auth) {
      case (?authInfo) { authInfo.principal };
      case (null) {
        return _returnError("Authentication required to add tasks.", cb);
      };
    };
    let description = switch (Result.toOption(Json.getAsText(args, "description"))) {
      case (?desc) { desc };
      case (null) {
        return _returnError("Missing 'description' argument.", cb);
      };
    };

    var user_data = Option.get(Map.get(task_data, Map.phash, caller), { tasks = Map.new<Nat, Task>(); var next_id = 0 });
    let new_id = user_data.next_id;
    let new_task : Task = {
      id = new_id;
      description = description;
      completed = false;
    };

    Map.set(user_data.tasks, Map.nhash, new_id, new_task);
    user_data.next_id += 1;
    Map.set(task_data, Map.phash, caller, user_data);

    let structuredPayload = _taskToJson(new_task);
    cb(#ok({ content = [#text({ text = Json.stringify(structuredPayload, null) })]; isError = false; structuredContent = ?structuredPayload }));
  };

  // Logic for listing all tasks for the current user.
  func listTasks(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) : async () {
    let caller = switch (auth) {
      case (?authInfo) { authInfo.principal };
      case (null) {
        return _returnError("Authentication required to list tasks.", cb);
      };
    };

    var tasks_array : [McpTypes.JsonValue] = [];
    switch (Map.get(task_data, Map.phash, caller)) {
      case (?user_data) {
        for ((id, task) in Map.entries(user_data.tasks)) {
          tasks_array := Array.append(tasks_array, [_taskToJson(task)]);
        };
      };
      case (null) { /* No tasks yet, return empty array */ };
    };

    let structuredPayload = Json.obj([("tasks", Json.arr(tasks_array))]);
    cb(#ok({ content = [#text({ text = Json.stringify(structuredPayload, null) })]; isError = false; structuredContent = ?structuredPayload }));
  };

  // Logic for updating a task's completion status.
  func updateTaskStatus(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) : async () {
    let caller = switch (auth) {
      case (?authInfo) { authInfo.principal };
      case (null) {
        return _returnError("Authentication required to update tasks.", cb);
      };
    };
    let task_id = switch (Result.toOption(Json.getAsInt(args, "task_id"))) {
      case (?id) { Int.abs(id) };
      case (null) {
        return _returnError("Missing 'task_id' argument.", cb);
      };
    };
    let completed = switch (Result.toOption(Json.getAsBool(args, "completed"))) {
      case (?c) { c };
      case (null) {
        return _returnError("Missing 'completed' argument.", cb);
      };
    };

    switch (Map.get(task_data, Map.phash, caller)) {
      case (?user_data) {
        switch (Map.get(user_data.tasks, Map.nhash, task_id)) {
          case (?task) {
            let updated_task = { task with completed = completed };
            Map.set(user_data.tasks, Map.nhash, task_id, updated_task);
            Map.set(task_data, Map.phash, caller, user_data); // Persist the change
            let structuredPayload = _taskToJson(updated_task);
            return cb(#ok({ content = [#text({ text = Json.stringify(structuredPayload, null) })]; isError = false; structuredContent = ?structuredPayload }));
          };
          case (null) {
            return _returnError("Task with id " # Nat.toText(task_id) # " not found.", cb);
          };
        };
      };
      case (null) {
        return _returnError("No tasks found for this user.", cb);
      };
    };
  };

  // Logic for deleting a task.
  func deleteTask(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) : async () {
    let caller = switch (auth) {
      case (?authInfo) { authInfo.principal };
      case (null) {
        return _returnError("Authentication required to delete tasks.", cb);
      };
    };
    let task_id = switch (Result.toOption(Json.getAsInt(args, "task_id"))) {
      case (?id) { Int.abs(id) };
      case (null) {
        return _returnError("Missing 'task_id' argument.", cb);
      };
    };

    switch (Map.get(task_data, Map.phash, caller)) {
      case (?user_data) {
        if (Option.isSome(Map.get(user_data.tasks, Map.nhash, task_id))) {
          Map.delete(user_data.tasks, Map.nhash, task_id);
          Map.set(task_data, Map.phash, caller, user_data); // Persist the change
          let structuredPayload = Json.obj([("status", Json.str("success"))]);
          return cb(#ok({ content = [#text({ text = Json.stringify(structuredPayload, null) })]; isError = false; structuredContent = ?structuredPayload }));
        } else {
          return _returnError("Task with id " # Nat.toText(task_id) # " not found.", cb);
        };
      };
      case (null) {
        return _returnError("No tasks found for this user.", cb);
      };
    };
  };

  // --- 3. CONFIGURE THE SDK ---
  transient let mcpConfig : McpTypes.McpConfig = {
    self = Principal.fromActor(self);
    allowanceUrl = ?allowanceUrl;
    serverInfo = {
      name = "io.github.jneums.taskpad";
      title = "TaskPad On-Chain To-Do List";
      version = "0.1.4";
    };
    resources = []; // No static resources for this app
    resourceReader = func(_) { null };
    tools = tools;
    toolImplementations = [
      ("add_task", addTask),
      ("list_tasks", listTasks),
      ("update_task_status", updateTaskStatus),
      ("delete_task", deleteTask),
    ];
    beacon = beaconContext;
  };

  // --- 4. CREATE THE SERVER LOGIC ---
  transient let mcpServer = Mcp.createServer(mcpConfig);

  // --- PUBLIC ENTRY POINTS (Unchanged from boilerplate) ---

  public query func get_owner() : async Principal { return owner };
  public shared ({ caller }) func set_owner(new_owner : Principal) : async Result.Result<(), Payments.TreasuryError> {
    if (caller != owner) { return #err(#NotOwner) };
    owner := new_owner;
    return #ok(());
  };
  public shared func get_treasury_balance(ledger_id : Principal) : async Nat {
    return await Payments.get_treasury_balance(Principal.fromActor(self), ledger_id);
  };
  public shared ({ caller }) func withdraw(ledger_id : Principal, amount : Nat, destination : Payments.Destination) : async Result.Result<Nat, Payments.TreasuryError> {
    return await Payments.withdraw(caller, owner, ledger_id, amount, destination);
  };

  private func _create_http_context() : HttpHandler.Context {
    return {
      self = Principal.fromActor(self);
      active_streams = appContext.activeStreams;
      mcp_server = mcpServer;
      streaming_callback = http_request_streaming_callback;
      auth = authContext;
      http_asset_cache = ?http_assets.cache;
      mcp_path = ?"/mcp";
    };
  };

  public query func http_request(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    switch (HttpHandler.http_request(ctx, req)) {
      case (?mcpResponse) { return mcpResponse };
      case (null) {
        return {
          status_code = 404;
          headers = [];
          body = Blob.fromArray([]);
          upgrade = null;
          streaming_strategy = null;
        };
      };
    };
  };

  public shared func http_request_update(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    let mcpResponse = await HttpHandler.http_request_update(ctx, req);
    switch (mcpResponse) {
      case (?res) { return res };
      case (null) {
        return {
          status_code = 404;
          headers = [];
          body = Blob.fromArray([]);
          upgrade = null;
          streaming_strategy = null;
        };
      };
    };
  };

  public query func http_request_streaming_callback(token : HttpTypes.StreamingToken) : async ?HttpTypes.StreamingCallbackResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    return HttpHandler.http_request_streaming_callback(ctx, token);
  };

  /**
   * Creates a new API key. This API key is linked to the caller's principal.
   * @param name A human-readable name for the key.
   * @returns The raw, unhashed API key. THIS IS THE ONLY TIME IT WILL BE VISIBLE.
   */
  public shared (msg) func create_my_api_key(name : Text, scopes : [Text]) : async Text {
    switch (authContext) {
      case (null) {
        Debug.trap("Authentication is not enabled on this canister.");
      };
      case (?ctx) {
        return await ApiKey.create_my_api_key(
          ctx,
          msg.caller,
          name,
          scopes,
        );
      };
    };
  };

  /** Revoke (delete) an API key owned by the caller.
   * @param key_id The ID of the key to revoke.
   * @returns True if the key was found and revoked, false otherwise.
   */
  public shared (msg) func revoke_my_api_key(key_id : Text) : async () {
    switch (authContext) {
      case (null) {
        Debug.trap("Authentication is not enabled on this canister.");
      };
      case (?ctx) {
        return ApiKey.revoke_my_api_key(ctx, msg.caller, key_id);
      };
    };
  };

  /** List all API keys owned by the caller.
   * @returns A list of API key metadata (but not the raw keys).
   */
  public query (msg) func list_my_api_keys() : async [AuthTypes.ApiKeyMetadata] {
    switch (authContext) {
      case (null) {
        Debug.trap("Authentication is not enabled on this canister.");
      };
      case (?ctx) {
        return ApiKey.list_my_api_keys(ctx, msg.caller);
      };
    };
  };

  /// (5.1) Upgrade finished stub
  public type UpgradeFinishedResult = {
    #InProgress : Nat;
    #Failed : (Nat, Text);
    #Success : Nat;
  };
  private func natNow() : Nat {
    return Int.abs(Time.now());
  };
  public func icrc120_upgrade_finished() : async UpgradeFinishedResult {
    #Success(natNow());
  };
};
