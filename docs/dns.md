# DNS Configuration Guide for Azure PDS

This guide covers DNS configuration options for the Azure PDS deployment, including automatic DNS record creation and manual DNS setup procedures.

## Overview

The Azure PDS infrastructure supports two DNS configuration approaches:

1. **Automatic DNS Management** - The Bicep template creates DNS records in an existing Azure DNS zone
2. **Manual DNS Configuration** - DNS records are created and managed outside of Azure (external DNS providers)

## Automatic DNS Management

### Prerequisites
- An existing Azure DNS zone for your domain
- DNS Zone Contributor permissions on the target DNS zone
- Domain delegation properly configured to Azure DNS

### Configuration Parameters

When deploying with automatic DNS management, provide these parameters:

```bash
# DNS zone name (the domain you own)
dnsZoneName="example.com"

# DNS record name (subdomain for your PDS)
dnsRecordName="pds"

# This will create records for:
# - pds.example.com (main PDS endpoint)
# - *.pds.example.com (wildcard for subdomains)
```

### Deployment Example

```bash
az deployment group create \
  --resource-group <RESOURCE_GROUP> \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=<PREFIX> \
    pdsHostname="pds.example.com" \
    pdsImageTag=<TAG> \
    adminObjectId=<ADMIN_OBJECT_ID> \
    emailFromAddress=<EMAIL_FROM> \
    pdsJwtSecretName=<JWT_SECRET_NAME> \
    pdsAdminPasswordSecretName=<ADMIN_PASSWORD_SECRET_NAME> \
    pdsPlcRotationKeySecretName=<PLC_KEY_SECRET_NAME> \
    smtpSecretName=<SMTP_SECRET_NAME> \
    dnsZoneName="example.com" \
    dnsRecordName="pds"
```

### Records Created

The template automatically creates these DNS records:

1. **Main CNAME Record**: `pds.example.com` → Container App FQDN
2. **Wildcard CNAME Record**: `*.pds.example.com` → Container App FQDN

### Verification

Verify automatic DNS configuration:

```bash
# Check if DNS zone exists
az network dns zone show --name "example.com" --resource-group <RG>

# List CNAME records
az network dns record-set cname list \
  --zone-name "example.com" \
  --resource-group <RG> \
  --output table

# Test DNS resolution
nslookup pds.example.com
nslookup test.pds.example.com
```

## Manual DNS Configuration

### When to Use Manual Configuration

- Domain is managed by an external DNS provider (Cloudflare, Route 53, etc.)
- Corporate DNS policies require external management
- Need custom DNS configurations not supported by Azure DNS
- Using CDN or traffic management services

### Setup Process

1. **Deploy without DNS parameters**:
   ```bash
   az deployment group create \
     --resource-group <RESOURCE_GROUP> \
     --template-file infra/main.bicep \
     --parameters \
       namePrefix=<PREFIX> \
       pdsHostname="pds.example.com" \
       [other-parameters-without-dns]
   ```

2. **Get Container App FQDN from deployment output**:
   ```bash
   CONTAINER_APP_FQDN=$(az deployment group show \
     --resource-group <RESOURCE_GROUP> \
     --name <DEPLOYMENT_NAME> \
     --query "properties.outputs.containerAppFqdn.value" \
     --output tsv)
   
   echo "Container App FQDN: $CONTAINER_APP_FQDN"
   ```

3. **Create DNS records with your DNS provider**:
   - **Main CNAME**: `pds.example.com` → `$CONTAINER_APP_FQDN`
   - **Wildcard CNAME**: `*.pds.example.com` → `$CONTAINER_APP_FQDN`

### Provider-Specific Instructions

#### Cloudflare
1. Log into Cloudflare dashboard
2. Select your domain
3. Go to DNS management
4. Add CNAME records:
   - Name: `pds`, Content: `<container-app-fqdn>`, Proxy: Optional
   - Name: `*.pds`, Content: `<container-app-fqdn>`, Proxy: Optional

#### AWS Route 53
```bash
# Create CNAME record
aws route53 change-resource-record-sets \
  --hosted-zone-id <ZONE_ID> \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "pds.example.com",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "<container-app-fqdn>"}]
      }
    }]
  }'
```

#### Google Cloud DNS
```bash
gcloud dns record-sets transaction start --zone=<ZONE_NAME>
gcloud dns record-sets transaction add <container-app-fqdn> \
  --name=pds.example.com. \
  --ttl=300 \
  --type=CNAME \
  --zone=<ZONE_NAME>
gcloud dns record-sets transaction execute --zone=<ZONE_NAME>
```

### Manual Configuration Verification

```bash
# Test DNS resolution
nslookup pds.example.com
dig pds.example.com CNAME

# Test wildcard resolution
nslookup test.pds.example.com
dig test.pds.example.com CNAME

# Check propagation globally
# Use online tools like whatsmydns.net or dnschecker.org
```

## DNS Propagation and Timing

### Expected Propagation Times
- **Local resolvers**: 0-30 minutes
- **Global propagation**: 4-24 hours
- **CDN edge servers**: 1-48 hours

### Factors Affecting Propagation
- TTL (Time To Live) values set on DNS records
- DNS resolver caching policies
- Geographic location of DNS queries
- DNS provider infrastructure

### Monitoring Propagation

```bash
# Check from multiple locations
dig @8.8.8.8 pds.example.com CNAME      # Google DNS
dig @1.1.1.1 pds.example.com CNAME      # Cloudflare DNS
dig @208.67.222.222 pds.example.com CNAME # OpenDNS

# Check TTL values
dig pds.example.com | grep -E "IN\s+CNAME|^\s*[0-9]+"
```

## SSL/TLS Certificate Management

### Automatic Certificate Issuance

The PDS Container App uses Caddy for automatic HTTPS certificate management:

1. **Let's Encrypt Integration**: Caddy automatically requests certificates
2. **Domain Validation**: Uses HTTP-01 or TLS-ALPN-01 challenges
3. **Auto-Renewal**: Certificates renewed automatically before expiration

### Certificate Verification

```bash
# Check certificate details
echo | openssl s_client -servername pds.example.com \
  -connect pds.example.com:443 2>/dev/null | \
  openssl x509 -noout -text | grep -E "Issuer|Subject|Not After"

# Check certificate chain
curl -I https://pds.example.com

# Test SSL configuration
nmap --script ssl-enum-ciphers -p 443 pds.example.com
```

### Certificate Troubleshooting

Common issues and solutions:

#### Challenge Failures
- **Symptoms**: Certificate issuance fails, HTTP errors
- **Solutions**: 
  - Verify DNS records point to correct FQDN
  - Check firewall rules allow HTTP/HTTPS traffic
  - Ensure port 80 is accessible for HTTP challenges

#### Wrong Certificate Issued
- **Symptoms**: Browser warnings, certificate name mismatch
- **Solutions**:
  - Verify `pdsHostname` parameter matches DNS records
  - Check Caddy configuration in container logs
  - Wait for DNS propagation before certificate requests

#### Certificate Not Renewing
- **Symptoms**: Certificate expiration warnings
- **Solutions**:
  - Check Container App is running continuously
  - Review Caddy logs for renewal errors
  - Ensure persistent storage for certificate data

## Advanced DNS Configurations

### Traffic Management

#### Weighted Routing (Manual Setup)
For blue-green deployments or A/B testing:

```bash
# 90% traffic to primary, 10% to canary
# Primary: pds.example.com (weight 90)
# Canary: pds-canary.example.com (weight 10)
```

#### Geographic Routing
Route traffic based on user location:
- `pds-us.example.com` → US Container App instance
- `pds-eu.example.com` → EU Container App instance
- `pds.example.com` → Primary/failover instance

### Health Check Integration

Configure DNS-based health checks:

```bash
# Health check endpoint
curl -f https://pds.example.com/xrpc/_health

# DNS failover based on health
# Configure with your DNS provider's health check features
```

### CDN Integration

#### Azure Front Door
1. Create Front Door profile
2. Add PDS Container App as backend
3. Configure custom domain with Front Door FQDN
4. Update DNS records to point to Front Door

#### Cloudflare Proxy
1. Enable Cloudflare proxy on DNS records
2. Configure SSL/TLS settings
3. Set up page rules for caching
4. Monitor performance and security metrics

## Monitoring and Alerting

### DNS Monitoring

Set up monitoring for:
- DNS resolution response times
- Certificate expiration dates
- DNS record changes
- SSL/TLS configuration health

### Azure Monitor Integration

```bash
# Create DNS resolution test
az monitor app-insights web-test create \
  --resource-group <RG> \
  --name "PDS DNS Test" \
  --location <LOCATION> \
  --web-test-kind "ping" \
  --url "https://pds.example.com/xrpc/_health"
```

### External Monitoring Tools

Recommended third-party services:
- **Pingdom**: Uptime and performance monitoring
- **StatusCake**: Global DNS and SSL monitoring  
- **Site24x7**: Comprehensive DNS and certificate monitoring
- **DNSPerf**: DNS performance analysis

## Security Considerations

### DNS Security Best Practices

1. **DNSSEC**: Enable DNS Security Extensions if supported
2. **CAA Records**: Specify authorized Certificate Authorities
3. **Access Control**: Limit DNS zone modification permissions
4. **Monitoring**: Alert on unexpected DNS changes

### CAA Record Example

```dns
; Authorize Let's Encrypt for certificate issuance
example.com. CAA 0 issue "letsencrypt.org"
example.com. CAA 0 issuewild "letsencrypt.org"
example.com. CAA 0 iodef "mailto:security@example.com"
```

### DNS Logging and Auditing

Enable DNS query logging:
- Azure DNS: Enable diagnostic logs
- External providers: Configure query logs
- Monitor for suspicious DNS queries
- Alert on high query volumes or unusual patterns

## Troubleshooting Common Issues

### DNS Resolution Failures

#### Issue: nslookup returns NXDOMAIN
**Cause**: DNS record doesn't exist or hasn't propagated
**Solution**:
1. Verify record was created correctly
2. Check DNS zone delegation
3. Wait for propagation (up to 48 hours)
4. Test with different DNS servers

#### Issue: CNAME points to wrong target
**Cause**: Incorrect Container App FQDN configured
**Solution**:
1. Get correct FQDN from deployment output
2. Update DNS record with correct target
3. Wait for propagation

### Certificate Issues

#### Issue: Certificate warnings in browser
**Cause**: DNS/certificate name mismatch
**Solution**:
1. Verify DNS records point correctly
2. Check `pdsHostname` deployment parameter
3. Review Caddy logs for certificate errors
4. Restart Container App if needed

#### Issue: HTTP instead of HTTPS
**Cause**: Certificate not issued or Caddy misconfiguration
**Solution**:
1. Check Caddy logs for certificate issuance
2. Verify DNS is resolving correctly
3. Ensure ports 80/443 are accessible
4. Review Container App configuration

### Performance Issues

#### Issue: Slow DNS resolution
**Cause**: High TTL, distant DNS servers, or DNS provider issues
**Solution**:
1. Lower TTL values (but increase query load)
2. Use geographically distributed DNS
3. Implement DNS caching strategies
4. Consider CDN with DNS optimization

#### Issue: SSL handshake slow
**Cause**: Certificate chain issues or cipher selection
**Solution**:
1. Optimize certificate chain
2. Review Caddy TLS configuration
3. Monitor SSL handshake performance
4. Consider TLS session resumption

## Migration and Updates

### Changing DNS Providers

1. **Lower TTL** before migration (24-48 hours ahead)
2. **Create records** in new DNS provider
3. **Update nameservers** at domain registrar
4. **Monitor propagation** and resolution
5. **Raise TTL** after successful migration

### Updating Container App FQDN

1. **Deploy with new FQDN** parameter
2. **Update DNS records** to point to new endpoint
3. **Test both old and new endpoints** during transition
4. **Remove old DNS records** after verification

### Blue-Green DNS Switching

1. **Deploy new environment** with different hostname
2. **Test new environment** thoroughly
3. **Update DNS records** to point to new environment
4. **Monitor** for issues and rollback if needed
5. **Decommission old environment** after success period

This guide should be regularly updated to reflect changes in DNS technologies, Azure services, and organizational requirements.