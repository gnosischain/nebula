FROM golang:1.23-alpine AS builder

WORKDIR /build
RUN apk add --no-cache git gcc musl-dev

RUN git clone --branch clickhouse-support --depth 1 --single-branch https://github.com/dennis-tra/nebula.git . \
    && git fetch --depth 1 origin a592a633f3581ba033754b9056a01941cbd49c7c \
    && git checkout a592a633f3581ba033754b9056a01941cbd49c7c

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
