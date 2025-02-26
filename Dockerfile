FROM golang:1.23-alpine AS builder

WORKDIR /build
RUN apk add --no-cache git gcc musl-dev

RUN git clone --branch clickhouse-support --depth 1 --single-branch https://github.com/dennis-tra/nebula.git . \
    && git fetch --depth 1 origin 920421de5bfece7de21962f999a196399e148abe \
    && git checkout 920421de5bfece7de21962f999a196399e148abe

RUN go mod download

RUN CGO_ENABLED=1 GOOS=linux go build -o nebula ./cmd/nebula

# ------------------------------------------------------------------------------

FROM alpine:latest

RUN adduser -D -H nebula
USER nebula
WORKDIR /home/nebula

COPY --from=builder /build/nebula /usr/local/bin/nebula

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s \
  CMD nebula health

CMD ["nebula"]
