const ClientSocket = @import("ClientSocket.zig");
const WireObject = @import("../implementation/WireObject.zig");

base: WireObject,
client: *ClientSocket,

const Self = @This();
