package apparmor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	deviceConfig "github.com/canonical/lxd/lxd/device/config"
	"github.com/canonical/lxd/lxd/instance/instancetype"
	"github.com/canonical/lxd/shared"
	"github.com/canonical/lxd/shared/api"
)

type forkproxyTestInstance struct {
	path string
}

func (i *forkproxyTestInstance) Project() api.Project {
	return api.Project{Name: api.ProjectDefaultName}
}

func (i *forkproxyTestInstance) Name() string {
	return "test"
}

func (i *forkproxyTestInstance) ExpandedConfig() map[string]string {
	return nil
}

func (i *forkproxyTestInstance) Type() instancetype.Type {
	return instancetype.VM
}

func (i *forkproxyTestInstance) LogPath() string {
	return filepath.Join(i.path, "logs")
}

func (i *forkproxyTestInstance) Path() string {
	return i.path
}

func (i *forkproxyTestInstance) DevicesPath() string {
	return filepath.Join(i.path, "devices")
}

type forkproxyTestDevice struct {
	config deviceConfig.Device
}

func (d *forkproxyTestDevice) Config() deviceConfig.Device {
	return d.config
}

func (d *forkproxyTestDevice) Name() string {
	return "proxy"
}

func TestForkproxyProfileVMUnixSockets(t *testing.T) {
	instancePath := t.TempDir()
	for _, name := range []string{"agent.crt", "agent-client.crt", "agent-client.key"} {
		require.NoError(t, os.WriteFile(filepath.Join(instancePath, name), nil, 0600))
	}

	inst := &forkproxyTestInstance{path: instancePath}
	tests := []struct {
		name    string
		bind    string
		listen  string
		connect string
		allowed string
		denied  string
	}{
		{
			name:    "Host bound",
			bind:    "host",
			listen:  "/tmp/lxd-test-host-listen.sock",
			connect: "/tmp/lxd-test-guest-connect.sock",
			allowed: "/tmp/lxd-test-host-listen.sock",
			denied:  "/tmp/lxd-test-guest-connect.sock",
		},
		{
			name:    "Instance bound",
			bind:    "instance",
			listen:  "/tmp/lxd-test-guest-listen.sock",
			connect: "/tmp/lxd-test-host-connect.sock",
			allowed: "/tmp/lxd-test-host-connect.sock",
			denied:  "/tmp/lxd-test-guest-listen.sock",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dev := &forkproxyTestDevice{config: deviceConfig.Device{
				"bind":    test.bind,
				"listen":  "unix:" + test.listen,
				"connect": "unix:" + test.connect,
			}}

			profile, err := forkproxyProfile(inst, dev)
			require.NoError(t, err)

			allowed := `"` + shared.HostPath(test.allowed) + `" rw,`
			denied := `"` + shared.HostPath(test.denied) + `" rw,`
			require.True(t, strings.Contains(profile, allowed), profile)
			require.NotContains(t, profile, denied)
		})
	}
}
