package chaos

import (
	"fmt"
	"math/big"
	"testing"
	"time"

	"github.com/onsi/gomega"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap/zapcore"

	"github.com/smartcontractkit/chainlink-testing-framework/blockchain"
	ctf_config "github.com/smartcontractkit/chainlink-testing-framework/config"
	"github.com/smartcontractkit/chainlink-testing-framework/k8s/chaos"
	"github.com/smartcontractkit/chainlink-testing-framework/k8s/environment"
	"github.com/smartcontractkit/chainlink-testing-framework/k8s/pkg/cdk8s/blockscout"
	"github.com/smartcontractkit/chainlink-testing-framework/k8s/pkg/helm/chainlink"
	"github.com/smartcontractkit/chainlink-testing-framework/k8s/pkg/helm/ethereum"
	"github.com/smartcontractkit/chainlink-testing-framework/logging"
	"github.com/smartcontractkit/chainlink-testing-framework/networks"
	"github.com/smartcontractkit/chainlink-testing-framework/utils/ptr"
	"github.com/smartcontractkit/chainlink-testing-framework/utils/testcontext"

	"github.com/smartcontractkit/chainlink/integration-tests/actions"
	"github.com/smartcontractkit/chainlink/integration-tests/client"
	"github.com/smartcontractkit/chainlink/integration-tests/contracts"
	eth_contracts "github.com/smartcontractkit/chainlink/integration-tests/contracts/ethereum"

	tc "github.com/smartcontractkit/chainlink/integration-tests/testconfig"
)

var (
	baseTOML = `[Feature]
LogPoller = true

[OCR2]
Enabled = true

[P2P]
[P2P.V2]
AnnounceAddresses = ["0.0.0.0:6690"]
ListenAddresses = ["0.0.0.0:6690"]`

	defaultAutomationSettings = map[string]interface{}{
		"replicas": 6,
		"toml":     "",
		"db": map[string]interface{}{
			"stateful": true,
			"capacity": "1Gi",
			"resources": map[string]interface{}{
				"requests": map[string]interface{}{
					"cpu":    "250m",
					"memory": "256Mi",
				},
				"limits": map[string]interface{}{
					"cpu":    "250m",
					"memory": "256Mi",
				},
			},
		},
	}

	defaultEthereumSettings = ethereum.Props{
		Values: map[string]interface{}{
			"resources": map[string]interface{}{
				"requests": map[string]interface{}{
					"cpu":    "4000m",
					"memory": "4Gi",
				},
				"limits": map[string]interface{}{
					"cpu":    "4000m",
					"memory": "4Gi",
				},
			},
			"geth": map[string]interface{}{
				"blocktime": "1",
			},
		},
	}

	defaultOCRRegistryConfig = contracts.KeeperRegistrySettings{
		PaymentPremiumPPB:    uint32(200000000),
		FlatFeeMicroLINK:     uint32(0),
		BlockCountPerTurn:    big.NewInt(10),
		CheckGasLimit:        uint32(2500000),
		StalenessSeconds:     big.NewInt(90000),
		GasCeilingMultiplier: uint16(1),
		MinUpkeepSpend:       big.NewInt(0),
		MaxPerformGas:        uint32(5000000),
		FallbackGasPrice:     big.NewInt(2e11),
		FallbackLinkPrice:    big.NewInt(2e18),
		MaxCheckDataSize:     uint32(5000),
		MaxPerformDataSize:   uint32(5000),
	}
)

func getDefaultAutomationSettings(config *tc.TestConfig) map[string]interface{} {
	defaultAutomationSettings["toml"] = networks.AddNetworksConfig(baseTOML, config.Pyroscope, networks.MustGetSelectedNetworkConfig(config.Network)[0])
	return defaultAutomationSettings
}

func getDefaultEthereumSettings(config *tc.TestConfig) *ethereum.Props {
	network := networks.MustGetSelectedNetworkConfig(config.Network)[0]
	defaultEthereumSettings.NetworkName = network.Name
	defaultEthereumSettings.Simulated = network.Simulated
	defaultEthereumSettings.WsURLs = network.URLs

	return &defaultEthereumSettings
}

type KeeperConsumerContracts int32

const (
	BasicCounter KeeperConsumerContracts = iota

	defaultUpkeepGasLimit = uint32(2500000)
	defaultLinkFunds      = int64(9e18)
	numberOfUpkeeps       = 2
)

func TestAutomationChaos(t *testing.T) {
	t.Parallel()
	l := logging.GetTestLogger(t)

	registryVersions := map[string]eth_contracts.KeeperRegistryVersion{
		"registry_2_0": eth_contracts.RegistryVersion_2_0,
		"registry_2_1": eth_contracts.RegistryVersion_2_1,
		"registry_2_2": eth_contracts.RegistryVersion_2_2,
	}

	for name, registryVersion := range registryVersions {
		rv := registryVersion
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			config, err := tc.GetConfig("Chaos", tc.Automation)
			if err != nil {
				t.Fatal(err)
			}

			var overrideFn = func(_ interface{}, target interface{}) {
				ctf_config.MustConfigOverrideChainlinkVersion(config.GetChainlinkImageConfig(), target)
				ctf_config.MightConfigOverridePyroscopeKey(config.GetPyroscopeConfig(), target)
			}

			chainlinkCfg := chainlink.NewWithOverride(0, getDefaultAutomationSettings(&config), config.ChainlinkImage, overrideFn)

			testCases := map[string]struct {
				networkChart environment.ConnectedChart
				clChart      environment.ConnectedChart
				chaosFunc    chaos.ManifestFunc
				chaosProps   *chaos.Props
			}{
				// see ocr_chaos.test.go for comments
				PodChaosFailMinorityNodes: {
					ethereum.New(getDefaultEthereumSettings(&config)),
					chainlinkCfg,
					chaos.NewFailPods,
					&chaos.Props{
						LabelsSelector: &map[string]*string{ChaosGroupMinority: ptr.Ptr("1")},
						DurationStr:    "1m",
					},
				},
				PodChaosFailMajorityNodes: {
					ethereum.New(getDefaultEthereumSettings(&config)),
					chainlinkCfg,
					chaos.NewFailPods,
					&chaos.Props{
						LabelsSelector: &map[string]*string{ChaosGroupMajority: ptr.Ptr("1")},
						DurationStr:    "1m",
					},
				},
				PodChaosFailMajorityDB: {
					ethereum.New(getDefaultEthereumSettings(&config)),
					chainlinkCfg,
					chaos.NewFailPods,
					&chaos.Props{
						LabelsSelector: &map[string]*string{ChaosGroupMajority: ptr.Ptr("1")},
						DurationStr:    "1m",
						ContainerNames: &[]*string{ptr.Ptr("chainlink-db")},
					},
				},
				NetworkChaosFailMajorityNetwork: {
					ethereum.New(getDefaultEthereumSettings(&config)),
					chainlinkCfg,
					chaos.NewNetworkPartition,
					&chaos.Props{
						FromLabels:  &map[string]*string{ChaosGroupMajority: ptr.Ptr("1")},
						ToLabels:    &map[string]*string{ChaosGroupMinority: ptr.Ptr("1")},
						DurationStr: "1m",
					},
				},
				NetworkChaosFailBlockchainNode: {
					ethereum.New(getDefaultEthereumSettings(&config)),
					chainlinkCfg,
					chaos.NewNetworkPartition,
					&chaos.Props{
						FromLabels:  &map[string]*string{"app": ptr.Ptr("geth")},
						ToLabels:    &map[string]*string{ChaosGroupMajorityPlus: ptr.Ptr("1")},
						DurationStr: "1m",
					},
				},
			}

			for name, testCase := range testCases {
				name := name
				testCase := testCase
				t.Run(fmt.Sprintf("Automation_%s", name), func(t *testing.T) {
					t.Parallel()
					network := networks.MustGetSelectedNetworkConfig(config.Network)[0] // Need a new copy of the network for each test

					testEnvironment := environment.
						New(&environment.Config{
							NamespacePrefix: fmt.Sprintf("chaos-automation-%s", name),
							TTL:             time.Hour * 1,
							Test:            t,
						}).
						AddHelm(testCase.networkChart).
						AddHelm(testCase.clChart).
						AddChart(blockscout.New(&blockscout.Props{
							Name:    "geth-blockscout",
							WsURL:   network.URL,
							HttpURL: network.HTTPURLs[0],
						}))
					err = testEnvironment.Run()
					require.NoError(t, err, "Error setting up test environment")
					if testEnvironment.WillUseRemoteRunner() {
						return
					}

					err = testEnvironment.Client.LabelChaosGroup(testEnvironment.Cfg.Namespace, "instance=node-", 1, 2, ChaosGroupMinority)
					require.NoError(t, err)
					err = testEnvironment.Client.LabelChaosGroup(testEnvironment.Cfg.Namespace, "instance=node-", 3, 5, ChaosGroupMajority)
					require.NoError(t, err)
					err = testEnvironment.Client.LabelChaosGroup(testEnvironment.Cfg.Namespace, "instance=node-", 2, 5, ChaosGroupMajorityPlus)
					require.NoError(t, err)

					chainClient, err := blockchain.NewEVMClient(network, testEnvironment, l)
					require.NoError(t, err, "Error connecting to blockchain")
					contractDeployer, err := contracts.NewContractDeployer(chainClient, l)
					require.NoError(t, err, "Error building contract deployer")

					chainlinkNodes, err := client.ConnectChainlinkNodes(testEnvironment)
					require.NoError(t, err, "Error connecting to Chainlink nodes")
					chainClient.ParallelTransactions(true)

					// Register cleanup for any test
					t.Cleanup(func() {
						if chainClient != nil {
							chainClient.GasStats().PrintStats()
						}
						err := actions.TeardownSuite(t, testEnvironment, chainlinkNodes, nil, zapcore.PanicLevel, &config, chainClient)
						require.NoError(t, err, "Error tearing down environment")
					})

					txCost, err := chainClient.EstimateCostForChainlinkOperations(1000)
					require.NoError(t, err, "Error estimating cost for Chainlink Operations")
					err = actions.FundChainlinkNodes(chainlinkNodes, chainClient, txCost)
					require.NoError(t, err, "Error funding Chainlink nodes")

					linkToken, err := contractDeployer.DeployLinkTokenContract()
					require.NoError(t, err, "Error deploying LINK token")

					registry, registrar := actions.DeployAutoOCRRegistryAndRegistrar(
						t,
						rv,
						defaultOCRRegistryConfig,
						linkToken,
						contractDeployer,
						chainClient,
					)

					// Fund the registry with LINK
					err = linkToken.Transfer(registry.Address(), big.NewInt(0).Mul(big.NewInt(1e18), big.NewInt(int64(numberOfUpkeeps))))
					require.NoError(t, err, "Funding keeper registry contract shouldn't fail")

					actions.CreateOCRKeeperJobs(t, chainlinkNodes, registry.Address(), network.ChainID, 0, rv)
					nodesWithoutBootstrap := chainlinkNodes[1:]
					defaultOCRRegistryConfig.RegistryVersion = rv
					ocrConfig, err := actions.BuildAutoOCR2ConfigVars(t, nodesWithoutBootstrap, defaultOCRRegistryConfig, registrar.Address(), 30*time.Second, registry.ChainModuleAddress(), registry.ReorgProtectionEnabled())
					require.NoError(t, err, "Error building OCR config vars")

					if rv == eth_contracts.RegistryVersion_2_0 {
						err = registry.SetConfig(defaultOCRRegistryConfig, ocrConfig)
					} else {
						err = registry.SetConfigTypeSafe(ocrConfig)
					}
					require.NoError(t, err, "Registry config should be be set successfully")
					require.NoError(t, chainClient.WaitForEvents(), "Waiting for config to be set")

					consumersConditional, upkeepidsConditional := actions.DeployConsumers(t, registry, registrar, linkToken, contractDeployer, chainClient, numberOfUpkeeps, big.NewInt(defaultLinkFunds), defaultUpkeepGasLimit, false, false)
					consumersLogtrigger, upkeepidsLogtrigger := actions.DeployConsumers(t, registry, registrar, linkToken, contractDeployer, chainClient, numberOfUpkeeps, big.NewInt(defaultLinkFunds), defaultUpkeepGasLimit, true, false)

					consumers := append(consumersConditional, consumersLogtrigger...)
					upkeepIDs := append(upkeepidsConditional, upkeepidsLogtrigger...)

					for _, c := range consumersLogtrigger {
						err = c.Start()
						require.NoError(t, err, "Error starting consumer")
					}

					l.Info().Msg("Waiting for all upkeeps to be performed")

					gom := gomega.NewGomegaWithT(t)
					gom.Eventually(func(g gomega.Gomega) {
						// Check if the upkeeps are performing multiple times by analyzing their counters and checking they are greater than 10
						for i := 0; i < len(upkeepIDs); i++ {
							counter, err := consumers[i].Counter(testcontext.Get(t))
							require.NoError(t, err, "Failed to retrieve consumer counter for upkeep at index %d", i)
							expect := 5
							l.Info().Int64("Upkeeps Performed", counter.Int64()).Int("Upkeep ID", i).Msg("Number of upkeeps performed")
							g.Expect(counter.Int64()).Should(gomega.BeNumerically(">=", int64(expect)),
								"Expected consumer counter to be greater than %d, but got %d", expect, counter.Int64())
						}
					}, "5m", "1s").Should(gomega.Succeed()) // ~1m for cluster setup, ~2m for performing each upkeep 5 times, ~2m buffer

					_, err = testEnvironment.Chaos.Run(testCase.chaosFunc(testEnvironment.Cfg.Namespace, testCase.chaosProps))
					require.NoError(t, err)

					gom.Eventually(func(g gomega.Gomega) {
						// Check if the upkeeps are performing multiple times by analyzing their counters and checking they are greater than 10
						for i := 0; i < len(upkeepIDs); i++ {
							counter, err := consumers[i].Counter(testcontext.Get(t))
							require.NoError(t, err, "Failed to retrieve consumer counter for upkeep at index %d", i)
							expect := 10
							l.Info().Int64("Upkeeps Performed", counter.Int64()).Int("Upkeep ID", i).Msg("Number of upkeeps performed")
							g.Expect(counter.Int64()).Should(gomega.BeNumerically(">=", int64(expect)),
								"Expected consumer counter to be greater than %d, but got %d", expect, counter.Int64())
						}
					}, "3m", "1s").Should(gomega.Succeed()) // ~1m for cluster setup, ~2m for performing each upkeep 5 times, ~2m buffer
				})
			}

		})
	}
}
