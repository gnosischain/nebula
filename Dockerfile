FROM golang:1.23-alpine AS builder

WORKDIR /build
RUN apk add --no-cache git gcc musl-dev

# upstream main HEAD as of 2026-04-23
RUN git clone --depth 1 --single-branch --branch main https://github.com/dennis-tra/nebula.git . \
    && git fetch --depth 1 origin 7cf39ac8b5a172b226086ee05c14913ab25a22d3 \
    && git checkout 7cf39ac8b5a172b226086ee05c14913ab25a22d3

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
