# One Ragnarok workspace

Ragnarok now includes the ALEXUS Mac workspace through the local `AlexusKit` package in `../alexus`. The original Swift sources remain shared with the iOS companion; there is no second copied implementation of chat, deployments, catalog or device approval.

| Main tab | Tools |
| --- | --- |
| Projects | My projects (the former Hub), work catalog, Terminal |
| Chat | Conversation (existing local/cloud providers), local tool chat, shared Room |
| Tasks | Agent runs, step-by-step local jobs, Conveyor |
| Activity | Timeline, companion repair receipt history |
| Money | Existing money and receipt tools |
| Home | Home Assistant |
| Settings | Devices and security, companion repairs, Foundation/about |

Each section has a labeled secondary picker. Legacy destinations remain valid: `hub`, `shell`, `alexus`, `room`, `agents`, `belt`, `timeline`, `money`, `home`. The Hub's Room/Home shortcuts and existing URL/Control Center handlers use the same destination state. Once visited, secondary tools retain their view state while switching.

Activity uses Ragnarok's timeline and agent run list rather than adding the companion's duplicate project/agent-summary screen. It adds only the unique companion repair receipts. Project management and the public evidence catalog stay separate views inside Projects because they have different data and actions.

## Boundaries

The existing Ragnarok unlock gate is unchanged. Device pairing, enrollment, repair proofs, private storage and host policy are unchanged. The package bundles the original Python hosts, signed Enclave helper, Foundation data and brand image. `ALEXUSSourceRoot` records the original sibling companion source root; private host state remains in its existing location.

Companion repairs explicitly target ALEXUS and its configured iOS companion. They still require both fresh hardware proofs. They do not install over Ragnarok. A companion source repair needs a subsequent Ragnarok rebuild to appear in its compiled shared module. Updating that host's release transaction to install Ragnarok instead is not part of this integration. The standalone companion build remains available for its existing hardware-authorized release workflow; it need not be used for normal Mac navigation. Existing installed ALEXUS copies and private chats are not removed.

The iOS Xcode entry point and pairing bridge remain available. Physical device pairing and proof ceremonies are not established by compilation or screenshots.

## Verify

From `app/heimdall`:

```sh
./make-app.sh
build/Heimdall.app/Contents/MacOS/Heimdall --selftest
python3 checks/workspace-integration-check.py
build/Heimdall.app/Contents/MacOS/Heimdall --render-tab workspace:about /tmp/ragnarok-workspace.png
```

From `app/alexus`, `./check.sh` builds/tests the Mac and simulator companion and runs the existing host checks. Neither command authorizes a repair or a physical device enrollment.
