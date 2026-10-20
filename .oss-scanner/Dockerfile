ARG FOUNDRY_VERSION=1.7.1
FROM --platform=linux/amd64 ghcr.io/foundry-rs/foundry:v${FOUNDRY_VERSION}

# SHA-256: https://github.com/argotorg/solc-bin/blob/gh-pages/linux-amd64/list.json
ADD --chmod=0755 --checksum=sha256:c42aada7a52057ddbed93ec011235e256c564c440b68dbaac5ae482babbb3d6d https://raw.githubusercontent.com/argotorg/solc-bin/gh-pages/linux-amd64/solc-linux-amd64-v0.8.25+commit.b61c2a91 /usr/local/bin/solc
ENV FOUNDRY_OFFLINE=true

# Build and test a fresh checkout, including its Foundry dependencies.
RUN git clone --recurse-submodules https://github.com/fabrica-land/metastreet-contracts-v2.git /tmp/src
WORKDIR /tmp/src
RUN forge build --use /usr/local/bin/solc
RUN forge test --use /usr/local/bin/solc
