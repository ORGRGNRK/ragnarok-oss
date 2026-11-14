# Kokoro text-to-speech for Home Assistant (Wyoming protocol, streaming), CPU only so it never
# competes with Ollama for the GTX 1080. Code pinned to one commit of debackerl/wyoming-kokoro-torch (MIT).
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends espeak-ng git && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
RUN git clone https://github.com/debackerl/wyoming-kokoro-torch /app \
 && cd /app && git checkout 7fd22aed2dcf12ffacd8d11ecd03f48aed524a8a \
 && pip install --no-cache-dir -e . \
 && python -m spacy download en_core_web_sm
WORKDIR /app
EXPOSE 10400
ENTRYPOINT ["python", "-m", "wyoming_kokoro_torch", "--uri", "tcp://0.0.0.0:10400", "--data-dir", "/data", "--download-dir", "/data", "--device", "cpu", "--streaming", "--volume", "2.0"]
CMD ["--voice", "af_heart"]
