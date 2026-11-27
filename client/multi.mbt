// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
/// Submit all operations in one ZooKeeper multi request. A lost reply to a
/// possibly sent transaction raises OutcomeUnknown.
pub async fn Client::multi(
  self : Client,
  ops : Array[@moonkeeper.MultiOp],
) -> @moonkeeper.MultiOutcome {
  // Keep response matching independent of later changes to the caller's array.
  let batch = ops.copy()
  self.request(
    xid => {
      @moonkeeper.encode_multi_request(
        xid,
        batch,
        max_frame_size=self.max_frame_size,
      )
    },
    payload => @moonkeeper.decode_multi_response(payload, batch),
    true,
  )
}
