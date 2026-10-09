FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f AS build
# Free Pascal 3.2.2 from Debian, which packages the compiler for amd64 and for arm64. The compiler and its run-time
# library and component library units are all the harness and the library need.
RUN apt-get update \
 && apt-get install -y --no-install-recommends fp-compiler-3.2.2 fp-units-rtl-3.2.2 fp-units-fcl-3.2.2 curl jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Optionally pin the library's version so `build-all` can rebuild historical versions. An empty value (the normal
# build) takes the latest release (tagged pas-v<version> in Corvus.JsonSchema). A release is a source archive.
ARG IMPLEMENTATION_VERSION
RUN version="${IMPLEMENTATION_VERSION}" \
 && if [ -z "$version" ]; then \
      version=$(curl -sSfL "https://api.github.com/repos/corvus-dotnet/Corvus.JsonSchema/releases?per_page=100" \
        | jq -r '[.[] | select(.tag_name | startswith("pas-v")) | select((.draft or .prerelease) | not)][0].tag_name | ltrimstr("pas-v")'); \
    fi \
 && curl -sSfL "https://github.com/corvus-dotnet/Corvus.JsonSchema/releases/download/pas-v$version/corvus-json-schema-pascal-$version.tar.gz" | tar -xz -C /opt \
 && mv "/opt/corvus-json-schema-$version" /opt/corvus-json-schema
COPY bowtie_corvus_json_schema.pas /src/
RUN mkdir /build \
 && fpc -O3 -Fu/opt/corvus-json-schema/src -Fi/opt/corvus-json-schema/src -FU/build -FE/build \
      /src/bowtie_corvus_json_schema.pas

# The program is linked statically and calls the kernel itself, so the image holds nothing else.
FROM scratch
COPY --from=build /build/bowtie_corvus_json_schema /usr/local/bin/
CMD ["/usr/local/bin/bowtie_corvus_json_schema"]
