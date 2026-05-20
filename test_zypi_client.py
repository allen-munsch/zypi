from zypi_client import ZypiClient

client = ZypiClient('http://localhost:4000', default_image='ubuntu:24.04')

# Health check
print('Health:', client.health_check())

# Run a simple command
exit_code, stdout, stderr = client.exec(['echo', 'Hello from Firecracker!'])
print(f'Exit: {exit_code}')
print(f'Stdout: {stdout}')
print(f'Stderr: {stderr}')
