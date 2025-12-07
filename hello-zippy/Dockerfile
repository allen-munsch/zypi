FROM python:3.11-alpine
ARG VERSION=1
COPY hello.py /app/hello.py
RUN echo "# Version: ${VERSION}" >> /app/hello.py
CMD ["python", "/app/hello.py"]