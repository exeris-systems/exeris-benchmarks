package eu.exeris.kernel.benchmark.target.api;

import java.util.Objects;

public record BenchmarkRuntimeDescriptor(
        String tier,
        String runtimeFamily,
        String protocolModeSelected,
        String implementationVariant,
        String providerId,
        String bootstrapContractVersion,
        String scenarioCatalogVersion,
        String telemetryProfile,
        String publicationPolicy) {

    public BenchmarkRuntimeDescriptor {
        tier = Objects.requireNonNull(tier, "tier");
        runtimeFamily = Objects.requireNonNull(runtimeFamily, "runtimeFamily");
        protocolModeSelected = Objects.requireNonNull(protocolModeSelected, "protocolModeSelected");
        implementationVariant = Objects.requireNonNull(implementationVariant, "implementationVariant");
        providerId = Objects.requireNonNull(providerId, "providerId");
        bootstrapContractVersion = Objects.requireNonNull(bootstrapContractVersion, "bootstrapContractVersion");
        scenarioCatalogVersion = Objects.requireNonNull(scenarioCatalogVersion, "scenarioCatalogVersion");
        telemetryProfile = Objects.requireNonNull(telemetryProfile, "telemetryProfile");
        publicationPolicy = Objects.requireNonNull(publicationPolicy, "publicationPolicy");
    }
}