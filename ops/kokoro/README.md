# kokoro

Kokoro text-to-speech for Home Assistant's Assist (added 2026-11-13: the tsundere voice).
Container `ragnarok-kokoro` on the `voice-net` Docker network, Wyoming on port 10400 (127.0.0.1 only on the host).
Home Assistant reaches it as `ragnarok-kokoro:10400` (Wyoming integration). CPU only. Model files download into data/.

The model is NOT downloaded by the server; fetch it once into data/ (about 330 MB):

    cd ~yggdrasil/Developer/ragnarok/ops/kokoro/data
    curl -fLO https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/kokoro-v1_0.pth
    curl -fLO https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/config.json

Each voice (af_bella.pt etc.) downloads by itself the first time it is used.

Build and run (as a sudo user):

    sudo docker build -t ragnarok-kokoro ~yggdrasil/Developer/ragnarok/ops/kokoro
    sudo docker run -d --name ragnarok-kokoro --restart unless-stopped --network voice-net \
      -p 127.0.0.1:10400:10400 -v ~yggdrasil/Developer/ragnarok/ops/kokoro/data:/data ragnarok-kokoro

Voices: pick in Home Assistant (Settings, Voice assistants, the assistant, Text-to-speech). American female voices start with af_.

Home Assistant: Wyoming integration entry `kokoro` (host ragnarok-kokoro, port 10400) gives `tts.kokoro`.
The server loads the model on every connection, so each reply starts about 2 to 3 seconds late (measured 2026-11-13).
