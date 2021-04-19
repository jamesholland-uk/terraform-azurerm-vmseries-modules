resource "azurerm_resource_group" "this" {
  count = var.existing_resource_group_name == null ? 1 : 0

  location = var.location
  name     = coalesce(var.create_resource_group_name, "${var.name_prefix}-vmseries-rg")
}

locals {
  resource_group_name = coalesce(var.existing_resource_group_name, azurerm_resource_group.this[0].name)
}

resource "random_password" "this" {
  length           = 16
  min_lower        = 16 - 4
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
  override_special = "_%@"
}

module "vnet" {
  source = "../../modules/vnet"

  virtual_network_name    = var.virtual_network_name
  resource_group_name     = local.resource_group_name
  location                = var.location
  address_space           = var.address_space
  network_security_groups = var.network_security_groups
  route_tables            = var.route_tables
  subnets                 = var.subnets
  tags                    = var.vnet_tags
}

# Create public IPs for the Internet-facing data interfaces so they could talk outbound.
resource "azurerm_public_ip" "public" {
  for_each = var.vmseries

  name                = "${var.name_prefix}-${each.key}-public"
  location            = var.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "standard"
  tags                = var.common_vmseries_tags
}

# The Inbound Load Balancer for handling the traffic from the Internet.
module "inbound-lb" {
  source = "../../modules/inbound-load-balancer"

  location     = var.location
  name_prefix  = var.name_prefix
  frontend_ips = var.frontend_ips
}

# The Outbound Load Balancer for handling the traffic from the private networks.
module "outbound-lb" {
  source = "../../modules/outbound-load-balancer"

  location       = var.location
  name_prefix    = var.name_prefix
  backend-subnet = module.vnet.subnet_ids["subnet-private"]
}

# The storage account for VM-Series initialization.
module "bootstrap" {
  source = "../../modules/bootstrap"

  resource_group_name  = local.resource_group_name
  location             = var.location
  storage_account_name = var.storage_account_name
  files                = var.files
}

# Create the Availability Set only if we do not use Availability Zones.
# Each of these two mechanisms improves availability of the VM-Series.
resource "azurerm_availability_set" "this" {
  count = contains([for k, v in var.vmseries : try(v.avzone, null) != null], true) ? 0 : 1

  name                        = "${var.name_prefix}-avset"
  resource_group_name         = local.resource_group_name
  location                    = var.location
  platform_fault_domain_count = 2
}

# Common VM-Series for handling:
#   - inbound traffic from the Internet
#   - outbound traffic to the Internet
#   - internal traffic (also known as "east-west" traffic)
module "common_vmseries" {
  source   = "../../modules/vmseries"
  for_each = var.vmseries

  resource_group_name       = local.resource_group_name
  location                  = var.location
  name                      = "${var.name_prefix}-${each.key}"
  avset_id                  = try(azurerm_availability_set.this[0].id, null)
  avzone                    = try(each.value.avzone, null)
  username                  = var.username
  password                  = coalesce(var.password, random_password.this.result)
  img_version               = var.common_vmseries_version
  img_sku                   = var.common_vmseries_sku
  vm_size                   = var.common_vmseries_vm_size
  tags                      = var.common_vmseries_tags
  bootstrap_storage_account = module.bootstrap.storage_account
  bootstrap_share_name      = module.bootstrap.storage_share.name
  interfaces = [
    {
      name                = "${each.key}-mgmt"
      subnet_id           = lookup(module.vnet.subnet_ids, "subnet-mgmt", null)
      create_public_ip    = true
      enable_backend_pool = false
    },
    {
      name                 = "${each.key}-public"
      subnet_id            = lookup(module.vnet.subnet_ids, "subnet-public", null)
      public_ip_address_id = azurerm_public_ip.public[each.key].id
      lb_backend_pool_id   = module.inbound-lb.backend-pool-id
      enable_backend_pool  = true
    },
    {
      name                = "${each.key}-private"
      subnet_id           = lookup(module.vnet.subnet_ids, "subnet-private", null)
      enable_backend_pool = false

      # Optional static private IP
      private_ip_address = try(each.value.trust_private_ip, null)
    },
  ]

  depends_on = [module.bootstrap]
}
