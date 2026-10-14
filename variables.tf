
variable "subscription_id" {
  type = string
}

variable "admin_username" {
  type    = string
  default = "azadmin"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "my_ip" {
  type = string
}
