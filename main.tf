
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# 1. Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "uma-portfolio-rg"
  location = "Korea Central"
}

# 2. Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "uma-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

# 3. Subnet
resource "azurerm_subnet" "subnet" {
  name                 = "uma-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# 4. Public IP
resource "azurerm_public_ip" "pip" {
  name                = "uma-public-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# 5. Network Security Group
resource "azurerm_network_security_group" "nsg" {
  name                = "uma-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Allow website traffic
  security_rule {
    name                       = "Allow-HTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Allow SSH only from your IP
  security_rule {
    name                       = "Allow-SSH"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.my_ip
    destination_address_prefix = "*"
  }
}

# 6. Network Interface
resource "azurerm_network_interface" "nic" {
  name                = "uma-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

# 7. Attach NSG to NIC
resource "azurerm_network_interface_security_group_association" "nsg_assoc" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# 8. Create Linux VM using username and password
resource "azurerm_linux_virtual_machine" "vm" {
  name                = "uma-portfolio-vm"
  computer_name       = "umavm"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_D4lds_v6"

  admin_username = var.admin_username
  admin_password = var.admin_password

  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.nic.id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # SSH connection for Terraform provisioners
  connection {
    type     = "ssh"
    user     = var.admin_username
    password = var.admin_password
    host     = azurerm_public_ip.pip.ip_address
    timeout  = "10m"
  }
  # 9. Install Nginx
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y nginx",
      "sudo systemctl enable nginx",
      "sudo systemctl start nginx",
      "mkdir -p /tmp/portfolio"
    ]
  }

  # 10. Copy portfolio files to VM
  provisioner "file" {
    source      = "${path.module}/myportfolio/"
    destination = "/tmp/portfolio/"
  }

  # 11. Deploy portfolio into Nginx web directory
  provisioner "remote-exec" {
    inline = [
      "sudo cp -r /tmp/portfolio/. /var/www/html/",
      "sudo chown -R www-data:www-data /var/www/html/",
      "sudo nginx -t",
      "sudo systemctl reload nginx"
    ]
  }
}

# 12. Display website URL
output "portfolio_url" {
  value = "http://${azurerm_public_ip.pip.ip_address}"
}

# 13. Display VM public IP
output "vm_public_ip" {
  value = azurerm_public_ip.pip.ip_address
}


# Azure Storage Account for Portfolio Static Website
resource "azurerm_storage_account" "portfolio_storage" {
  name                     = "umaportfolio2026x"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = "portfolio"
    managed_by  = "terraform"
  }
}

# Enable Static Website Hosting
resource "azurerm_storage_account_static_website" "portfolio_website" {
  storage_account_id = azurerm_storage_account.portfolio_storage.id
  index_document     = "index.html"
  error_404_document = "404.html"
}

# Upload all portfolio files to the $web container
resource "azurerm_storage_blob" "portfolio_files" {
  for_each = fileset(path.module, "myportfolio/**/*")

  name                   = trimprefix(each.value, "myportfolio/")
  storage_account_name   = azurerm_storage_account.portfolio_storage.name
  storage_container_name = "$web"
  type                   = "Block"
  source                 = "${path.module}/${each.value}"

  content_type = lookup({
    html = "text/html"
    css  = "text/css"
    js   = "application/javascript"
    png  = "image/png"
    jpg  = "image/jpeg"
    jpeg = "image/jpeg"
    svg  = "image/svg+xml"
    pdf  = "application/pdf"
    ico  = "image/x-icon"
    webp = "image/webp"
    json = "application/json"
  }, lower(element(reverse(split(".", each.value)), 0)), "application/octet-stream")

  depends_on = [
    azurerm_storage_account_static_website.portfolio_website
  ]
}

# Display the website URL after deployment
output "storage_portfolio_url" {
  description = "Azure Storage Static Website URL"
  value       = azurerm_storage_account.portfolio_storage.primary_web_endpoint
}

output "portfolio_storage_account_name" {
  value = azurerm_storage_account.portfolio_storage.name
}
