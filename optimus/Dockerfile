# optimus/Dockerfile: image for the llama-optimus service (compose.yaml,
# "benchmark" profile only). Runs a pinned commit of
# github.com/BrunoArsioli/llama-optimus on top of the ramalama image, so
# llama-bench is the same binary ramalama serves with. Nothing on the host.
#
# Single RUN layer: git is installed, used and removed in the same layer,
# so neither it nor the .git history nor dnf/pip caches reach the image.
FROM localhost/my-ramalama-asahi:latest

ARG OPTIMUS_COMMIT=11ad87198e5cceb86d9fc0128960da7a24b0e89f
WORKDIR /opt/llama-optimus
RUN dnf install -y --nodocs git ca-certificates python3 python3-pip \
 && git clone https://github.com/BrunoArsioli/llama-optimus.git . \
 && git checkout "${OPTIMUS_COMMIT}" \
 && rm -rf .git \
 && pip install --no-cache-dir -r requirements.txt . \
 && dnf remove -y git \
 && dnf clean all \
 && rm -rf /var/cache/dnf

# LLAMA_BIN and MODEL_PATH are supplied at runtime in compose.yaml
ENTRYPOINT ["python3", "optimus.py"]
