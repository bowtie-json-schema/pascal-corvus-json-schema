# The library's source, as released (src-pas in Corvus.JsonSchema). Its version is this tag, which Dependabot keeps up
# to date.
FROM ghcr.io/corvus-dotnet/corvus-json-schema-pascal:0.1.1 AS corvus

FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS build
# Free Pascal 3.2.2 from Debian, which packages the compiler for amd64 and for arm64. The compiler and its run-time
# library and component library units are all the harness and the library need.
RUN apt-get update \
 && apt-get install -y --no-install-recommends fp-compiler-3.2.2 fp-units-rtl-3.2.2 fp-units-fcl-3.2.2 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=corvus /corvus-json-schema /opt/corvus-json-schema
COPY bowtie_corvus_json_schema.pas /src/
RUN mkdir /build \
 && fpc -O3 -Fu/opt/corvus-json-schema/src -Fi/opt/corvus-json-schema/src -FU/build -FE/build \
      /src/bowtie_corvus_json_schema.pas

# The program is linked statically and calls the kernel itself, so the image holds nothing else.
FROM scratch
COPY --from=build /build/bowtie_corvus_json_schema /usr/local/bin/
CMD ["/usr/local/bin/bowtie_corvus_json_schema"]
