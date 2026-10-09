# pascal-corvus-json-schema

A [Bowtie](https://github.com/bowtie-json-schema/bowtie) test harness for
[corvus-json-schema](https://github.com/corvus-dotnet/Corvus.JsonSchema/tree/main/src-pas/corvus-json-schema), the
Object Pascal port of [Corvus.JsonSchema](https://github.com/corvus-dotnet/Corvus.JsonSchema)'s V5 evaluator. It is
built with Free Pascal and has no dependencies.

Its image is published to `ghcr.io/bowtie-json-schema/pascal-corvus-json-schema` and run via
`bowtie run -i pascal-corvus-json-schema`.

The harness compiles each case's schema with the case's `registry` as the document resolver and validates each
instance. For `annotations` output it evaluates through a verbose collector and reports each annotation with its
instance location and `#…` keyword location. Requests are read with the library's own JSON parser, and schemas and
instances reach the evaluator as values of the parsed request, so their text is never written out again.

The image compiles the harness with the library's source from its latest release (a source archive, tagged
`pas-v<version>`). The `IMPLEMENTATION_VERSION` build argument pins another. The program is linked statically, so
the image holds nothing else.
