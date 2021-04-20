provider "azurerm" {
  features {}
}

# Pubic LB
module "public_lb" {
  source = "../../modules/loadbalancer"

  name_lb             = "LB-public"
  name_probe          = "Probe-public"
  location            = var.location
  resource_group_name = var.resource_group_name
  backend_name        = "backend1_name"
  frontend_ips = {
    # Map of maps (each object has one frontend to many backend relationship) 
    fe1-pip-existing = {
      create_public_ip         = false
      public_ip_name           = ""
      public_ip_resource_group = ""
      rules = {
        HTTP = {
          port     = 80
          protocol = "Tcp"
        }
      }
    }
    fe1-pip-create = {
      create_public_ip = true
      rules = {
        HTTPS = {
          port     = 8080
          protocol = "Tcp"
        }
        SSH = {
          port     = 22
          protocol = "Tcp"
        }
      }
    }
  }
}

#  Private LB
module "private_lb" {
  source = "../../modules/loadbalancer"

  name_lb             = "LB-private"
  name_probe          = "Probe-private"
  location            = var.location
  resource_group_name = var.resource_group_name
  backend_name        = "backend1_name"
  frontend_ips = {
    internal_fe = {
      subnet_id                     = ""
      private_ip_address_allocation = "Static" // Dynamic or Static
      private_ip_address            = "10.0.1.6"
      rules = {
        HA_PORTS = {
          port     = 0
          protocol = "All"
        }
      }
    }
  }
}
