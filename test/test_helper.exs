# Override data_dir for testing — avoids root requirement
Application.put_env(:zypi, :data_dir, System.get_env("ZYPI_TEST_DATA_DIR", "/tmp/zypi-test"))
Application.put_env(:zypi, :vm_pool, [min_warm: 0, max_warm: 0, max_total: 0])
Application.put_env(:zypi, :ssh_key_path, nil)

ExUnit.start(exclude: [:fabric, :integration, :chaos])

# Load fabric test support
Code.require_file("test/support/fabric_case.ex")
