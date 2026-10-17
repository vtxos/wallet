# vtxos wallet

**A passkey-based Bitcoin wallet with a Wasm cosigner: approve on your phone, verify the service you are trusting, and let previously authorized work continue while you are offline.**

vtxos holds Bitcoin as **Ark off-chain VTXOs**. Ordinary wallet signing uses a **2-of-2 FROST key** shared between the phone and a remote cosigner. The phone reconstructs its signing share for each operation from its passkey and the cosigner's stored contribution, rather than keeping a FROST share in the application's persistent state.

The [cosigner](https://github.com/vtxos/cosigner) is a Rust component running on [**the runtime**](https://github.com/vtxos/runtime). The runtime supplies attested HTTPS, passkey authorization, tenant-scoped encrypted storage, background scheduling, maintained connections, and device wake notifications. The wallet and its cosigner supply the wallet protocol, signing rules, Ark integration, and application policy.

That division supports more than interactive payments. A user can sign a bounded renewal delegate while present, then let the cosigner execute it with an Ark Service Provider (ASP) later. An explicitly paired escrow service can also initiate a policy-checked exchange through a connection the runtime maintains.

> **Development software; use test funds.** The documented local and MutinyNet environments use QEMU's emulated Nitro device and a development storage key. They exercise the integration but do not provide AWS Nitro's hardware trust boundary. Real Nitro deployment, independent security review, and resolution of wallet/runtime correctness findings remain prerequisites for production use.

## Contents

- [What the wallet implements](#what-the-wallet-implements)
- [Architecture](#architecture)
- [How the wallet uses the runtime](#how-the-wallet-uses-the-runtime)
- [A concrete demonstration: renew while the phone is offline](#a-concrete-demonstration-renew-while-the-phone-is-offline)
- [Attestation, authorization, and isolation](#attestation-authorization-and-isolation)
- [Build and run](#build-and-run)
- [Testing](#testing)
- [Repository guide](#repository-guide)
- [Security model summary](#security-model-summary)
- [No key at rest](#no-key-at-rest)
- [Trust assumptions & failure modes](#trust-assumptions--failure-modes)
- [Emergency exit](#emergency-exit)

## What the wallet implements

| Capability | What is in the repository |
|---|---|
| **Threshold wallet creation** | A distributed key-generation ceremony and FROST signing over secp256k1, with Taproot/BIP-340-compatible signatures. The protocol uses shares rather than reconstructing the full group private key. |
| **Passkey-based signing and restoration** | A passkey PRF derives the phone's contribution; an approved cosigner stream returns the complementary dealt contribution. The reconstructed share is checked against the wallet's expected verifying share. |
| **Ark payments** | Boarding deposits, VTXO discovery, sends, settlement, history, and renewed-fund tracking through an ASP. |
| **Delegated renewal** | The user signs a delegate over a known set of funds; a durable runtime task attempts that renewal when due. Completion or inability to renew can wake the owner. |
| **Policy-controlled escrows** | Escrow creation, service pairing, release checks, allowance/reference tracking, and replies over runtime-held service connections. |
| **Pre-signed exits** | Exit transaction construction and verification, coverage tracking, export, and ancestry display. The app does not yet broadcast the complete ancestor/exit chain. |
| **An attested native client** | Nonce-bound verification of runtime/guest measurements and the connection certificate before an approved gRPC interaction is sent. |
| **Development and integration tooling** | Android app, shared Dart core, regtest CLI, Rust/FFI tests, and QEMU end-to-end tests. |

These are implementation capabilities, not a claim that every environment is validated or every finding is closed. The [security findings](SECURITY_FINDINGS.md) track known concerns, including cross-device PRF behavior, secret lifetimes, and test coverage. Some older assessments still refer to components that have since been replaced; current source and the test entry points below describe the active architecture.

## Architecture

```mermaid
flowchart TB
    subgraph Phone[Android phone]
        App[Flutter wallet and Dart core]
        Passkey[Platform passkey and PRF]
        FFI[Rust threshold, Ark, and attestation FFI]
        Passkey --> App
        App --> FFI
    end
    subgraph Enclave[Enclave image: real Nitro target or QEMU development]
        Runtime[enclave-runtime: TLS, authentication, tenant locks]
        Guest[cosigner.wasm: signing, Ark state, policy]
        Storage[WASI filesystem over encrypted S3 blocks]
        Workers[Tasks, service connections, and device wakes]
        Runtime --> Guest
        Guest --> Storage
        Guest <--> Workers
    end
    App <-->|Attested HTTPS and gRPC streams| Runtime
    App <-->|Interactive Ark operations| ASP[Ark Service Provider]
    Guest <-->|Allowed origin: delegated work| ASP
    Workers <-->|SSE and POST| Service[Paired escrow service]
    Workers -->|Content-free wake| Push[AWS push → FCM]
    Push --> App
```

| Participant | Responsibility |
|---|---|
| **Phone** | User interaction, passkey approval/PRF, share reconstruction, its side of FROST, and interactive Ark orchestration. |
| **Cosigner guest** | Its signing share, persistent wallet state, validation of signing requests, delegates, escrows, and application-level replay/accounting rules. |
| **enclave-runtime** | Component execution, measured boot, key release, TLS, tenant identity and filesystem scope, serialization, and the host capabilities the guest calls. |
| **ASP** | Ark rounds, indexing, settlement, and the external service needed for normal Ark operations. |
| **Paired service** | An explicitly configured counterparty for an escrow, subject to that escrow's policy. It does not receive the user's passkey or general wallet authority. |

The current server artifact is [`cosigner.wasm`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/main.rs), built for `wasm32-wasip2`. It exports `wasi:http/incoming-handler`, `run-task`, and `on-message`. It has no listener, TLS server, or native per-user actor registry. The host library build exists for tests and development tools; running it as a standalone server is not the serving path.

## How the wallet uses the runtime

The wallet is a concrete consumer of the runtime's capabilities. The cosigner's [`Host` trait](https://github.com/vtxos/cosigner/blob/main/cosigner/src/host.rs) is implemented by the [WIT adapter](https://github.com/vtxos/cosigner/blob/main/cosigner/src/main.rs), and its [component world](https://github.com/vtxos/cosigner/blob/main/cosigner/wit/cosigner.wit) composes the tasks, notification, and stream interfaces.

| Wallet need | Runtime capability | Where the wallet uses it |
|---|---|---|
| Identify the service before sending an approval | Attestation on `/auth/*`, PCR0/PCR16, and certificate binding | [`attestation.dart`](core/lib/enclave/attestation.dart), [`gate.dart`](core/lib/enclave/gate.dart) |
| Carry multiple signing rounds under one approved interaction | Passkey-minted interaction token, HTTP/2, bidirectional request/response bodies | [`connection.dart`](core/lib/cosigner/connection.dart), [`session.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/session.rs), [`grpc/`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/grpc/) |
| Keep each wallet's files and execution separate | Tenant-scoped preopen and per-tenant execution lock | [`open_cosigner`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/main.rs), [`store.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/store.rs) |
| Preserve state beyond an invocation or restart | Copy-on-write encrypted filesystem and durable sync/rename operations | [`SnapshotState`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/types.rs), [`cosigner.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/cosigner.rs) |
| Execute an already authorized renewal later | `enclave:tasks/queue` and the `run-task` callback | [`renew.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/renew.rs), [`cosigner.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/cosigner.rs) |
| Reach the ASP during unattended work | The ASP named in the cosigner's measured settings; the runtime admits only public addresses (and the emulator's host) | [`asp/`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/asp/), [`up-enclave.sh`](scripts/up-enclave.sh) |
| Let a paired service initiate an exchange | `enclave:streams/connection` and `on-message` | [`escrow.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/escrow.rs) |
| Notify the owner without putting private details in a push | Runtime-owned device enrollment and a wake queue sent through AWS End User Messaging Push | [`host.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/host.rs), [`cosigner.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/cosigner.rs) |

### Persistent wallet state

The guest's store is a small **key-value layer over files**, not an embedded SQLite database. A value is stored at `<root>/<hex-tree>/<hex-key>`; writes use a temporary file and rename. Hex-encoded names prevent a caller-controlled key from becoming a filesystem path.

Those are ordinary files from the guest's perspective. Under enclave-runtime, they live inside the wallet's tenant scope and are backed by encrypted S3 slabs and signed filesystem roots. Snapshot serialization is the cosigner's responsibility; storage encryption, publication, and recovery are the runtime's. A native test using the same file store does not acquire enclave storage encryption automatically.

The runtime mounts one shared filesystem and gives each tenant a restricted view. It serializes that tenant's HTTP invocations, background work, and message callbacks. Healthy HTTP instances may be reused for the same tenant; callbacks and restarts can rebuild them. Durable wallet state belongs in the store, not in assumptions about an instance staying alive.

### A service can speak while the phone is absent

The service connection solves a separate problem from a timer. An escrow counterparty has no passkey for the user's tenant, and a Wasm guest cannot maintain its own execution context between calls. The runtime holds the connection and invokes the cosigner when a message arrives.

The guest checks that the sending service is paired to the named escrow and evaluates the stored session, transaction policy, remaining allowance, and required evidence. It tracks request IDs and consumed payment references in persistent state. Runtime reconnection does not itself provide exactly-once payments; the application-level accounting is essential.

Service destinations are configured in the measured image. The guest selects a service identity from that configuration; the wallet does not gain arbitrary outbound access by supplying a URL. See [`escrow.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/escrow.rs) and the [service-stream tests](https://github.com/vtxos/cosigner/blob/main/cosigner/tests/service_stream_test.rs).

## A concrete demonstration: renew while the phone is offline

This flow shows what the runtime contributes to a working wallet:

1. **Establish identity.** The app verifies the enclave's measurements and TLS certificate, enrolls a passkey, and completes DKG inside its tenant.
2. **Board and protect funds.** The phone and cosigner complete an Ark operation. While the phone is present, they sign a renewal delegate covering the known VTXOs; configured exit transactions can be signed alongside it.
3. **Persist the authorization.** The cosigner stores the delegate and enqueues `settle-watch`. The scheduler records the tenant and the due work outside the guest's invocation lifetime.
4. **Let the phone disconnect.** At the deadline, the runtime invokes `run-task` under that tenant's lock. The cosigner reloads its state and executes the stored delegate against the allowed ASP.
5. **Observe the result.** A successful refresh produces a new VTXO with a later expiry. The notification path can wake the owner; failure to complete the round is surfaced so the owner can act.
6. **Authorize the next cycle.** The new VTXO has no new phone-signed delegate yet. On return, the wallet protects the new funds again and updates its exit coverage.

**The authorization was signed before the phone went offline.** This is not authority for arbitrary new payments or an unlimited renewal loop. An unattended renewal also creates an output whose pre-signed exit must be obtained when the owner returns.

The [`the delegate` end-to-end test](e2e/test/enclave_ark_test.dart) exercises renewal without a new signing call from the client, checks the changed outpoint and later expiry, then verifies that the new funds need protection again. It polls the indexer to observe progress. Separate tests exercise changed-guest/certificate refusals, distinct tenants, share reconstruction, and escrow-service delivery.

For a presentation, show the approval, original and refreshed outpoints, the absence of a new phone signing operation, and the notification. Add a preserved-store restart as a separate persistence demonstration. Record the revision, test environment, and observed outcome; distinguish QEMU protocol checks from hardware-backed Nitro evidence.

## Attestation, authorization, and isolation

### Verify runtime, guest, and connection

The client checks three identities together:

- **PCR0:** the runtime image and its measured configuration.
- **PCR16:** the cosigner component, with the settings written into it at deployment, measured by that runtime before key release.
- **TLS leaf certificate:** the certificate of the connection that delivered the attested authentication response.

Each authentication request carries a fresh nonce. The client verifies the document's signature/chain, pinned root, expected measurements, nonce, timestamp, and connection binding through [`crates/enclave-client`](https://github.com/vtxos/cosigner/blob/main/crates/enclave-client/) and FFI. [`PinnedTransportConnector`](core/lib/enclave/pinned_transport.dart) then checks the certificate before handing a socket to the gRPC transport.

Attestation is carried on the runtime's `/auth/*` responses. Guest gRPC responses do not carry a separate response-signing key or an application-body signature from the runtime. Their transport is tied to the certificate already attested. Attestation identifies approved code and its connection; application checks still determine what it may sign.

### Approve an interaction

```text
request options → verify enclave → user-verified passkey assertion
                → single-use interaction token → approved gRPC stream
```

The runtime token binds the method, path, and query. It does not by itself approve every payload byte or every signing round. The wallet protocol must validate the transaction, policy, and cryptographic contributions inside the stream. A service-initiated escrow release uses the standing policy and paired service identity rather than manufacturing a fresh phone approval.

The passkey has two distinct roles: authenticating an interaction to the runtime and deriving the phone's contribution through the PRF. Their combination is the basis of the [no-key-at-rest flow](#no-key-at-rest).

### Intended Nitro trust boundary and current emulator

Production key release is designed around enclave-runtime's KMS recipient flow, with both PCR0 and PCR16 approved for `GenerateDataKey` and `Decrypt`. It is the external key policy—not a guest's assertion about itself—that controls which image/application can obtain storage key material. Production provisioning and hardware validation remain work to complete.

The QEMU environment generates its own attestation signing chain and uses a development storage key. Its operator can read state and forge documents under that emulator root. A public TLS certificate does not change that. The MutinyNet client obtains measurements and the emulator root from a deployment manifest; the publisher of that manifest is therefore part of the development trust configuration. Production measurement distribution needs its own reviewed trust policy.

## Build and run

### Prerequisites

The complete development stack targets **Linux with KVM and vsock**. Install:

- Rust and native C/C++ build tools, for the FFI.
- Dart for the client/CLI/tests and Flutter for the app. The app requires Dart `>=3.4.0 <4.0.0`; package manifests define the other SDK bounds.
- Docker with Compose, `protoc` and `pkg-config`. Nix with flakes only to build the enclave image from a runtime checkout (`make up`); the e2e runs a prebuilt image instead.
- `python3`, `jq`, `curl`, `openssl`, and standard Linux shell utilities.
- For Android: the Android SDK/ADB and NDK. The Makefile defaults to NDK `27.0.12077973`; override its build variables to match an intentional toolchain change.

The cosigner is [vtxos/cosigner](https://github.com/vtxos/cosigner), which builds and releases `cosigner.wasm`; its crates (`threshold`, `ark`, `enclave-client`) are `ffi/`'s git dependencies at the release tag `ffi/Cargo.toml` names, and `make proto` takes the protos from that same checkout, so `ffi/Cargo.lock` pins both. The enclave the e2e boots is the **dev enclave image** pinned in [`docker-compose.enclave.yml`](docker-compose.enclave.yml): [the runtime](https://github.com/vtxos/runtime)'s QEMU enclave and that cosigner release in one container, built by infra. The host needs Docker, KVM and vsock, and none of Nix, cargo, wasi-sdk or a runtime checkout. From the repository root:

```bash
sudo modprobe vsock_loopback

make enclave-image    # pull the pinned image; refused unless it serves the release ffi/ builds against
```

`make up-enclave` and runtime-side work still need a checkout (`~/enclave-runtime`, or `ENCLAVE_CHECKOUT`), since that image is built with the app's rp id and origins; it serves the image's cosigner (`make cosigner`), or `COSIGNER_WASM`, a build of your own:

```bash
export ENCLAVE_CHECKOUT="$HOME/enclave-runtime"
docker build -t enclave-qemu-nitro:latest "$ENCLAVE_CHECKOUT/deploy/qemu-nitro"
cargo install vhost-device-vsock --version 0.3.0 --locked \
  --root "$ENCLAVE_CHECKOUT/target/qemu-nitro/tools"
```

The runtime's [development guide](https://github.com/vtxos/runtime/blob/main/docs/DEV_ENCLAVE.md) describes the emulator prerequisites and network setup. The first image build can take much longer than a warm restart.

### Start a persistent regtest environment

```bash
make up
```

`make up` aliases `up-enclave`. It takes the released `cosigner.wasm` out of the dev enclave image, builds the host FFI, starts Bitcoin/Electrs and arkd, initializes the regtest chain and ASP, then runs the enclave in the foreground. The script mines regtest blocks while running and gives the cosigner its settings — the ASP and a development renewal margin — at boot.

The default enclave name is `vtxos`, the host TLS port is `8443`, and the store is retained across starts. Artifacts and pins live under `$ENCLAVE_CHECKOUT/target/qemu-nitro/vtxos`. The image includes the configured Android relying-party/origin settings; a custom app signing key requires the corresponding origin and domain association.

Stopping and restarting reloads the component and preserves the retained store. A changed component changes PCR16; the emulator trust root changes every boot. Rebuild/restart clients with the new development pins. `FRESH=1 make up` intentionally discards the retained enclave store and should only be used when a clean test state is wanted.

### Explore with the CLI

In another terminal:

```bash
make cli
```

At its prompt:

```text
new alice
whoami
fund 100000
balance
protect
```

Use `help` for sending and wallet switching. `whoami` displays the verified runtime/guest identity; `balance` reports held VTXOs and delegated protection. [`cli/`](cli/) uses software passkeys and is **regtest tooling**: its passkey files under `~/.merlin-cli` (or `MERLIN_CLI_HOME`) are plaintext capabilities to act as those test wallets. They are distinct from the Android platform-passkey model.

### Run the Android app

With the enclave running and the device connected:

```bash
rustup target add aarch64-linux-android
(cd app && flutter pub get)
make adb-reverse
make flutter
```

`make flutter` builds the Android FFI and reads this boot's trust root, TLS trust material, and measurements into the Flutter launch configuration. Plain `flutter run` without the correct configuration is not the equivalent. `ENCLAVE_RUN=/path/to/run` selects a different run directory; `flutter-32` and `flutter-x86` cover the additional build targets.

### Stop the environment

Stop the foreground `make up` with Ctrl-C, or use `make down-enclave` from another terminal. `make down` also stops the Compose services **and removes their volumes**, including the regtest/ASP state. Retaining enclave wallet files alone does not preserve a regtest chain that was deleted separately.

### The cosigner

Built, tested and released in [vtxos/cosigner](https://github.com/vtxos/cosigner). `make cosigner` writes the release this repository pins to `.cosigner/cosigner.wasm`; to run a change of your own before it is released, set `COSIGNER_WASM` to its build for `make up` or `make e2e`.

### MutinyNet development deployment

The MutinyNet deployment is [vtxos/infra](https://github.com/vtxos/infra)'s: the released cosigner in a Nitro enclave, and its runbook. Against it, from the repository root:

```bash
make mutinynet-smoke
```

The smoke command checks attestation, separate wallets, and DKG; its funded path uses the explicitly configured test-network funder. This is a test network.

## Testing

| Command | Purpose |
|---|---|
| `make ffi-test` | Tests for the merged native FFI library. |
| `make ffi-build` then `(cd core && dart pub get && dart test)` | Shared client tests, including share reconstruction, operation lifetimes, attestation, and persistence. |
| `(cd app && flutter test)` | Flutter tests after package setup. |
| `make e2e` | Builds the FFI, starts regtest/arkd, starts the dev enclave image and runs `e2e/test/enclave_ark_test.dart`. |
| `make e2e-all` | With an Android emulator up (API 34+): everything CI's e2e job runs. On one boot of the image's app bundle, with MerlinPlatform, the suite above, then the app's full flow (`app/integration_test/app_test.dart`): a passkey through Credential Manager to a test provider (`app/android/testpasskey`), DKG, boarding, the cosigner's own renewal, an entry, the Exit tab and a payout. See `scripts/e2e-all.sh`. |
| `make proto-check` | Verifies checked-in Dart stubs match the protobuf sources; requires `protoc` and the Dart plugin. |

The end-to-end suite covers measured-guest and certificate refusals, DKG, distinct tenants, boarding/settlement/sends, delegated renewal, contribution isolation, reconstructed shares, exits, and service pairing. These tests exist in the source; this README does not imply a fresh successful run of every suite.

For a complete E2E run, let the harness configure its own enclave. An existing one can be selected with:

```bash
make e2e-enclave ENCLAVE_RUN="$ENCLAVE_CHECKOUT/target/qemu-nitro/vtxos"
```

An attached enclave's cosigner must also name the suite's escrow-service fixture and use a renewal margin suitable for the test timeout. The delegate test reports a skip if the deadline is too far away. The image carries nothing of this suite's: the harness gives the cosigner the settings in `e2e/lib/e2e_profile.dart` when it starts it (`GUEST_ENV`), written into the component and measured into PCR16 with it. Only one emulator stack can own the fixed MinIO port/vsock configuration at a time.

CI (`.github/workflows/ci.yml`) runs the FFI's `cargo test`, every Dart package's analysis, `core`'s tests against the built FFI, the app's `flutter analyze` and `flutter test`, and every e2e: the `e2e` job runs `make e2e-all` on the runner's KVM (hosted runners have nested virtualisation; the runtime's own CI relies on the same), the suite and then the app on an emulator. Moving to a newer runtime or cosigner is infra's: it builds the image from its pins and prints the digest, which goes into `docker-compose.enclave.yml`, with the tags in `ffi/Cargo.toml` moved to the same cosigner release. A change to a ceremony is still run locally before it is called done. Host tests, QEMU integration tests, Android device tests, and real Nitro validation establish different properties.

## Repository guide

| Path | Responsibility |
|---|---|
| [`app/`](app/) | Flutter Android UI, passkey platform integration, onboarding, payments, and exit display. |
| [`core/`](core/) | Dart protocol orchestration, attested transport, passkey derivation, persistence, and Ark client operations. |
| [`cosigner/`](https://github.com/vtxos/cosigner/blob/main/cosigner/) | Rust Wasm component: gRPC handlers, signing, file-backed state, delegates, escrows, policy, and host capability bindings. |
| [`crates/threshold/`](https://github.com/vtxos/cosigner/blob/main/crates/threshold/) | FROST/DKG and supporting secp256k1 operations used by the guest and native FFI. |
| [`crates/ark/`](https://github.com/vtxos/cosigner/blob/main/crates/ark/) | Ark transaction/protocol primitives, delegate and exit construction, and contract VTXOs. |
| [`crates/enclave-client/`](https://github.com/vtxos/cosigner/blob/main/crates/enclave-client/) | Rust attestation verification used by the client through FFI. |
| [`ffi/`](ffi/) | The merged C ABI for threshold, Ark, and enclave functionality. |
| [`protocol/`](protocol/) | Protobuf contracts and generated Dart messages/stubs. |
| [`cli/`](cli/) | Regtest wallet REPL using software passkeys and the same client core; `bin/bob.dart` is Bob, the integration test's counterparty (`make bob-up`). |
| [`e2e/`](e2e/) | QEMU harness, regtest integration scenarios, and test escrow service. |
| [`scripts/`](scripts/) | Local stack startup, regtest and ASP setup, and development helpers. |

The runtime is maintained in its [separate repository](https://github.com/vtxos/runtime). It owns the measured host and storage machinery; [vtxos/cosigner](https://github.com/vtxos/cosigner) owns the application component, and this repository the wallet clients.

## Security model summary

- **Ordinary fresh wallet signatures require both FROST participants.** An unattended renewal executes an authorization the phone signed earlier; it does not give the cosigner the phone's share or permission for arbitrary new payments.
- **The current Android wallet state format stores no FROST share, dealer secret, or PRF output.** Public identifiers, transaction metadata, delegates, and pre-signed exits remain privacy-sensitive. Secret copies can still exist temporarily in Dart/FFI memory.
- **Passkey security is central.** The passkey's PRF plus an approved call to the correct cosigner reconstructs the phone's share. Restoration also depends on the cosigner retaining its state and the PRF behaving consistently on the restored device.
- **The runtime supplies tenant scope and serialization.** The cosigner's file store is scoped to one tenant; encryption comes from the runtime filesystem, not from merely serializing a snapshot.
- **Native clients verify PCR0, PCR16, and the connection certificate.** The provenance of their approved measurements and trust root is part of the security model.
- **Production key release must approve both runtime and guest.** QEMU's development key and signing chain provide no confidentiality from the emulator operator.
- **Pre-signed exits are limited recovery artifacts.** They cover specific outputs and destinations. Broadcasting ancestors, satisfying delays, and funding fees still matter; a phone-only recovery leaf is not implemented.

The same 2-of-2 requirement that prevents one participant creating an ordinary wallet signature alone creates an availability dependency on the cosigner. Read the [trust assumptions](#trust-assumptions--failure-modes) and [exit limitations](#emergency-exit) together with the [security findings](SECURITY_FINDINGS.md). The historical [production-readiness assessment](PRODUCTION_READINESS.md) is useful context, but includes findings against earlier server layouts and is not a current audit certificate.

## No key at rest

**Status: implemented, in a development build. Not production-ready.**

Here, “no key at rest” refers to the phone application's persisted FROST share and derivation
secrets. The platform passkey remains a credential, and the cosigner persists its own signing
share and the dealt contribution inside the runtime's encrypted store.

A share is the sum of both dealers' polynomials at the wallet's identifier:

```text
  s = f_wallet(id) + f_cosigner(id)
```

`f_wallet` is derived from the passkey's PRF output by a labelled HKDF
(`core/lib/passkey/key_derivation.dart`). `f_cosigner(id)` is one scalar, which the cosigner
sealed at DKG. Neither is the key. An operation that signs goes like this
(`MpcClient._withOperation`):

1. **Wait for a turn.** Operations that sign are serialized — one operation's secrets are never in
   memory beside another's, and the runtime runs one stream per tenant anyway.
2. **Read what is slow and not secret** (the ASP's parameters, the indexer's set) — before the
   approval, which is good for under a minute.
3. **One fingerprint.** The assertion that approves the call also evaluates the PRF
   (`SeedSource.seedDuring`). The seed becomes the polynomial and is overwritten at once. A passkey
   that does not derive this wallet's identifier is refused here, before anything is opened.
4. **Open the stream.** Its open names the wallet's identifier; the cosigner's first answer carries
   `wallet_dealt_share`, on `Sign`, `Send` and `Renew` alike — once per stream, and never the
   cosigner's own share ([`cosigner.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/cosigner.rs), `dealt_share_for`). No second call, so
   no second approval.
5. **Add, fix the sign, check.** The sum is accepted only if `s·G` is the verifying share this
   device stored when the wallet was made — not one that arrived with the contribution
   (`core/lib/passkey/share_reconstruction.dart`). The share signs every round of that stream:
   a renewal's intent proof, its commitment, the trailing seal.
6. **Let go**, in a `finally`: on success, on failure, and on cancellation
   (`MpcClient.cancelOperation`).

`Sign` had to change shape for this. The wallet used to commit first, and its nonce is hedged with
its share — which it no longer has until the cosigner answers. So the cosigner commits first, as it
always did on `Send` and `Renew`; FROST's binding factor covers every commitment whoever sent
theirs last. `Sign` is also now script-path only by name: it always was in effect, since the
cosigner signs untweaked and checks every share.

**Who may have the contribution.** The runtime gives each tenant its own filesystem scope and
execution slot over one shared encrypted filesystem. A cosigner invocation opens only that
tenant's wallet; the guest does not route between tenants. Within an instance it answers only
the identifier the ceremony recorded.
That identifier is public, so the check authenticates nobody; it tells a wallet that is not this
one — a wrong passkey, a PRF that answers differently — so, instead of handing it a scalar that
would not add up.

**What this changes in the threat model.** Copying the current wallet application state no longer
yields a persisted FROST share or dealer secret. Access to the platform passkey, live process
memory, old development files, or an unlocked device remains a separate concern. As with
`Recover`, a passkey's PRF output
plus an approved call is the wallet's half of the key. Releasing the contribution on every approved
operation gives an attacker who has both nothing they could not already ask for.

**What it does not promise.**

- **Not guaranteed zeroization.** The seed is bytes and is overwritten. Everything after it is a
  Dart `BigInt` — the coefficients, the share — which cannot be overwritten: references are dropped
  and the garbage collector reclaims the memory when it chooses, without clearing it. The FFI takes
  a key package as JSON, so signing makes short-lived string copies of the share. The PRF output
  reaches Dart as base64 inside a JSON string from the platform channel, and strings are immutable.
  This is reference hygiene with a checkable lifetime, not memory scrubbing.
- **No migration.** State written by an older build is refused by name
  (`IncompatibleWalletStateException`) and must be reset — the app offers it on launch, the CLI has
  `reset <name>` — after which the wallet is restored from its passkey. Hive is append-only, so
  only deleting the file removes what an older build wrote. A cosigner seal from before the dealt
  share was kept cannot serve any of this ("created before recovery existed"); that tenant has to
  be reset too.
- **No new offline capability, and none lost.** Signing always needed the cosigner — it is a 2-of-2
  — so rebuilding the share from it adds no dependency that was not there. A saved exit needs
  no fresh FROST signature, although its ancestors, delay, and fee funding still matter. The
  cosigner's unattended renewal executes a previously signed delegate without the phone's share.
- **PRF stability across devices is still assumed, not proved** — see `SECURITY_FINDINGS.md` RC-2.
  It now matters for every payment rather than only for recovery, which also means a PRF that
  drifted would be noticed on the first payment rather than on the day the phone is lost.

**Escrows follow the same rule.** An escrow share is the wallet share plus two deltas — the
wallet's, derived from the passkey under a per-escrow context, and the cosigner's, sealed — and is
rebuilt inside the same operation, from the two halves a reclaim (a `Send` naming the escrow)
brings on its first round, checked against the escrow's stored verifying share, and released with the operation
(`WalletOperation.escrowKeyPackage`). The operation that mints an escrow holds the share it made
(`WalletOperation.holdEscrowKeyPackage`) instead. What the device keeps of an escrow is its key,
its public package and that context; `Recover` hands a new device all three. An escrow minted
before its context was recorded cannot be rebuilt by any passkey and is left out of recovery.

An escrow a reclaim has been opened on is retired from deals, for good. Reclaim signatures stay
valid for as long as the outpoints they spend exist, and the cosigner can see neither whether they
left the device nor whether those outpoints are still there — so a deal struck over such an escrow
would be one the owner could empty at will. The mark is sealed before the reclaim's first nonce,
so an abandoned reclaim is as final as a finished one; the next deal gets a new escrow.

Tests: `core/test/share_reconstruction_test.dart`, `escrow_reconstruction_test.dart`,
`operation_lifecycle_test.dart` (a cosigner in-process; reads the box file back as raw bytes),
`cancel_streams_test.dart`, the cosigner's [`stream_contribution_test.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/tests/stream_contribution_test.rs) and [`seal_test.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/tests/seal_test.rs), and
the `nothing secret at rest`, `a wallet on a new phone` and `pairing a service into an escrow`
groups of `e2e/test/enclave_ark_test.dart`.

## Trust assumptions & failure modes

The security summary above is what holds when everything works. This is what breaks, and who
you have to trust for it not to.

### The one that matters: the Ark owner key is 2-of-2

Ordinary wallet VTXOs and boarding outputs use the **FROST group key** as their owner key
([`MpcClient._ownerXOnly`](core/lib/client.dart)). Escrow contracts have their own key and
policy arrangements. The stock Ark taptree used for ordinary wallet outputs has two spend paths:

```
forfeit leaf:  <asp_pk> OP_CHECKSIGVERIFY <owner_pk> OP_CHECKSIG
exit leaf:     <delay>  OP_CSV OP_DROP    <owner_pk> OP_CHECKSIG
```

See ark-core's [`Vtxo::new_default`](https://docs.rs/ark-core/0.9.1/src/ark_core/vtxo.rs.html#123) and its
[`multisig_script`](https://docs.rs/ark-core/0.9.1/src/ark_core/script.rs.html#23) and [`csv_sig_script`](https://docs.rs/ark-core/0.9.1/src/ark_core/script.rs.html#54) builders.

Both name `owner_pk`, and here it is the group key. The exit timelock controls
when funds can be spent; it does not remove the need for a group-key signature.
If the cosigner disappears, the wallet cannot create new signatures. Funds with
saved pre-signed exits can still be exited after publishing the required ancestor
transactions and satisfying the delay. Uncovered funds have no such fallback.
The app can export saved exits and display their ancestry, but does not broadcast
the full exit path. There is no separate on-chain wallet or offline spending mode.

### AWS and the runtime

The intended production deployment uses a real Nitro enclave and KMS recipient release bound to
both the runtime image and the cosigner component. Hardware isolation, key policy, authenticated
storage responses, correct runtime code, and correctly provisioned client pins all contribute to
that boundary. The runtime remains under correctness review; storage recovery and guest lifecycle
failures can directly affect wallet state and must be resolved before production use.

The parent can deny service. Loss of the cosigner's durable state or of the keys required to read
it prevents new signatures and share reconstruction unless an adequate recovery/backup arrangement
exists. The phone's public state does not replace the cosigner's share or dealt contribution.
Saved exits remain useful only for the specific outputs and destination they cover.

The dev enclave `make up` and the e2e run is emulated. Its operator controls the development
storage key and the attestation signing chain. The client exercises its
verification path against configured emulator pins; this does not establish confidentiality or
independent code identity against that operator.

### The ASP

Normal Ark operations depend on an available ASP and the protocol it implements. An unavailable
ASP can prevent sends, settlement, renewal, and discovery of current state. Owner signatures are
part of the spend authorization, but that does not remove the need to validate ASP responses or
provide a practical recovery path.

The available fallback is a covered pre-signed exit plus the necessary ancestor publication,
timelocks, and fees. The app can inspect/export the material it has; automatic full-chain exit
broadcasting and a general phone-only spending path are not implemented. The MutinyNet runbook
configures an external ASP rather than an ASP operated by this repository.

### What Ark's privacy does *not* give you

Keeping VTXOs off-chain does not hide all wallet activity from the services involved:

- **The ASP processes transaction information.** Inputs, outputs, amounts, and their relationships
  are available to it through the operations it serves. Treat it as a participant with access to
  sensitive payment metadata.
- **The cosigner also processes wallet metadata.** Its snapshot includes VTXOs, history,
  delegates, and escrow state. Production enclave storage is intended to keep this
  from the host operator; it does not make the data invisible to the approved application or
  eliminate implementation and logging risks.
- **Exiting is public and linking.** A unilateral exit publishes your branch of the VTXO tree
  on-chain, tying those outputs together for anyone watching.
- **Boarding and exit are on-chain events** with ordinary on-chain traceability.

Off-chain operation alone does not establish anonymity; evaluate the information disclosed to each participant.

## Emergency exit

**Status: exit construction, verification, and export are implemented. Full exit broadcasting
and a phone-only recovery leaf remain unfinished.**

When an external exit destination is configured, the seal at the end of an interactive wallet
operation can produce **pre-signed exit transactions** for eligible held VTXOs. The phone and
cosigner sign a spend through each output's existing exit leaf, paying the configured address in
a wallet this app does not control. The phone saves the transactions; the Exit tab displays them
and supports raw export. Outputs that cannot produce a valid exit, including those below the
builder's dust threshold, can remain uncovered. Without an exit destination, no exits are built.

An existing signature removes the need to ask the cosigner for another signature for that
covered spend. Publishing the required ancestors, satisfying the exit delay, and supplying fees
are still necessary. Coverage is specific to an output and destination, so spending or renewing
funds requires new exit material.

An unattended renewal creates a new output without a new phone-signed exit. Those funds remain
uncovered until the owner returns and completes another seal with an exit destination. The Exit
tab shows which held funds are covered and which are not.

An exit pays no fee. It carries a P2A anchor instead, so whoever broadcasts it attaches a child
that pays for both — a fee fixed at signing time would be a guess about a fee market years away,
and a wallet whose cosigner is gone cannot re-sign. Publishing the transactions that put the money
off-chain in the first place — the batch tree branch, and the checkpoint and Ark transactions for
funds not yet settled — is not in the app yet; the exit is the last hop, and the one that cannot be
obtained later.

Implementation: [`exit.rs`](https://github.com/vtxos/cosigner/blob/main/crates/ark/src/exit.rs) (shared transaction construction),
[`FFI exit verification`](ffi/src/ark/exit.rs), [`renew.rs`](https://github.com/vtxos/cosigner/blob/main/cosigner/src/renew.rs),
[`exit_plan.dart`](core/lib/sessions/exit_plan.dart), and
[`exit_screen.dart`](app/lib/screens/exit/exit_screen.dart).

### The better answer, still to come

A proposed **third taptree leaf spendable by a phone-controlled recovery key after a long CSV
delay** would address outputs for which no pre-signed exit was obtained. It is a design proposal,
not a currently usable recovery path:

```text
forfeit  leaf:  <asp_pk>       OP_CHECKSIGVERIFY <group_pk>    OP_CHECKSIG   # cooperative
exit     leaf:  <exit_delay>   OP_CSV OP_DROP    <group_pk>    OP_CHECKSIG   # still 2-of-2
recovery leaf:  <recov_delay>  OP_CSV OP_DROP    <recovery_pk> OP_CHECKSIG   # proposed
```

The candidate recovery scalar is the wallet's dealer secret `a0`, derived by
[`walletPolynomial`](core/lib/passkey/key_derivation.dart) from the passkey PRF. Its public
point could authorize a delayed recovery spend without reconstructing the ordinary group key.
That would still depend on possession of a functioning passkey and stable derivation.

The [contract VTXO builder](https://github.com/vtxos/cosigner/blob/main/crates/ark/src/lib.rs) already demonstrates separate cooperative and
exit-owner keys. This is useful implementation groundwork, not proof that a new ordinary-wallet
three-leaf design is compatible with every ASP, fee model, or recovery scenario. The recovery
key must be explicitly threaded and validated through the wallet/cosigner data model.

Work remaining includes the taptree/address changes on both sides, a reviewed recovery delay and
threat model, boarding/output migration, ASP compatibility checks, ancestor and fee handling, and
an app broadcast flow. Existing outputs would keep their existing scripts until moved into new
ones. A meaningful acceptance test would disable the cosigner and ASP and still recover covered
funds using only the intended recovery credentials and chain access.

The tradeoff also changes: an attacker who can use the recovery credential could spend after its
delay. That delay and the relationship to existing Ark scripts need protocol review. Pre-signed
exits remain the implemented mechanism while this broader path is unfinished.

## References

- [FROST: Flexible Round-Optimized Schnorr Threshold Signatures](https://eprint.iacr.org/2020/852)
- [BIP-340: Schnorr Signatures for secp256k1](https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki)
- [BIP-341: Taproot](https://github.com/bitcoin/bips/blob/master/bip-0341.mediawiki)
- [Ark protocol](https://arkdev.info/) — off-chain VTXOs via an Ark Service Provider
- [AWS Nitro Enclaves](https://docs.aws.amazon.com/enclaves/latest/user/nitro-enclave.html)
- [vtxos/runtime](https://github.com/vtxos/runtime) — the Wasm host, encrypted filesystem, attestation, and background capabilities the cosigner runs on

## License

This repository is [MIT-licensed](LICENSE). The app, the client core, the FFI and
repository-owned deployment code can be inspected and used under those terms. The cosigner and the
crates it shares with this repository are [vtxos/cosigner](https://github.com/vtxos/cosigner)'s.

Third-party dependencies retain their own licenses. The runtime lives in its separate
[Apache-2.0-declared workspace](https://github.com/vtxos/runtime/blob/main/Cargo.toml).
Every dependency retains its upstream licensing; this repository's MIT license does not replace
it.
