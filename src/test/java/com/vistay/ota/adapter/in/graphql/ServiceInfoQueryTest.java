package com.vistay.ota.adapter.in.graphql;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ServiceInfoQueryTest {

    private final ServiceInfoQuery query = new ServiceInfoQuery();

    @Test
    void exposesStableServiceIdentity() {
        var info = query.otaServiceInfo();

        assertThat(info.name()).isEqualTo("ota");
        assertThat(info.version()).isEqualTo("0.1.0");
    }
}

