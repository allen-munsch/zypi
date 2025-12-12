FROM golang:1.21-alpine AS build
ARG VERSION=1

WORKDIR /app
COPY hello.go .
RUN CGO_ENABLED=0 go build -o /hello-zypgo hello.go

FROM alpine:latest
COPY --from=build /hello-zypgo /hello-zypgo
CMD ["/hello-zypgo"]