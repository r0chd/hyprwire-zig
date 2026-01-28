pub const MessageType = enum(u8) {
    invalid = 0,

    ///  Sent by the client to initiate the handshake.
    ///  Params: str -> has to be "VAX"
    sup = 1,

    /// Sent by the server after a HELLO.
    /// Params: arr(uint) -> versions supported
    handshake_begin = 2,

    /// Sent by the client to confirm a choice of a protocol version
    /// Params: uint -> version chosen
    handshake_ack = 3,

    ///  Sent by the server to advertise supported protocols
    ///  Params: arr(str) -> protocols
    handshake_protocols = 4,

    ///  Sent by the client to bind to a specific protocol spec
    ///  Params: uint -> seq, str -> protocol spec
    bind_protocol = 10,

    ///  Sent by the server to acknowledge the bind and return a handle
    ///  Params: uint -> object handle ID, uint -> seq
    new_object = 11,

    ///  Sent by the server to indicate a fatal protocol error
    ///  Params: uint -> object handle ID, uint -> error idx, varchar -> error message
    fatal_protocol_error = 12,

    /// Sent from the client to initiate a roundtrip.
    /// Params: uint -> sequence
    roundtrip_request = 13,

    ///  Sent from the server to finalize the roundtrip.
    ///  Params: uint -> sequence
    roundtrip_done = 14,

    ///  Generic protocol message. Can be either direction.
    ///  Params: uint -> object handle ID, uint -> method ID, data...
    generic_protocol_message = 100,
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
