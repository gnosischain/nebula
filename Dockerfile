FROM golang:1.23-alpine AS builder

WORKDIR /build
RUN apk add --no-cache git gcc musl-dev

# release version 2.4.0
RUN git clone --depth 1 --single-branch --branch main https://github.com/dennis-tra/nebula.git . \
    && git fetch --depth 1 origin 5e53b575b55678eaab71fa6b666ff73db94e5c21 \
    && git checkout 5e53b575b55678eaab71fa6b666ff73db94e5c21

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
