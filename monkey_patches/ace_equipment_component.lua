local EquipmentComponent = require 'stonehearth.components.equipment.equipment_component'
local AceEquipmentComponent = class()

AceEquipmentComponent._ace_old_activate = EquipmentComponent.activate
function AceEquipmentComponent:activate()
   self:_ace_old_activate()

   if not self._sv.default_equipment then
      self._sv.default_equipment = {}
   end
end

function AceEquipmentComponent:equip_item(item, destroy_old_item)
   -- destroy the old item by default, unless explicitly told not to
   destroy_old_item = destroy_old_item ~= false

   -- if someone passes the uri, create an entity
   if type(item) == 'string' then
      item = radiant.entities.create_entity(item)
   elseif type(item) == 'table' then
      -- pick an random item from the array
      item = radiant.entities.create_entity(item[rng:get_int(1, #item)])
   end

   --TODO: Because of the current implementation of the shop, it is possible
   --to equip an item bought from the shop, and then sell that item off a
   --person's back. Final solution involves pausing the game while in the shop,
   --keeping track of all shop transactions, and then delivering results before
   --Once done, remove this code, because this mechanism of adding/removing to
   --the inventory is very brittle
   local inventory = stonehearth.inventory:get_inventory(radiant.entities.get_player_id(self._entity))
   if inventory then
      --There may not be an inventory in say, autotests
      inventory:remove_item(item:get_id())
   end

   -- if someone tries to equip a proxy, equip the full-sized item instead
   radiant.check.is_entity(item)
   local proxy = item:get_component('stonehearth:iconic_form')
   if proxy then
      item = proxy:get_root_entity()
   end
   local ep = item:get_component('stonehearth:equipment_piece')
   assert(ep, 'item is not an equipment piece')

   radiant.entities.set_player_id(item, self._entity)

   local slot = ep:get_slot()

   if not slot then
      -- no slot specified, make up a magic slot name
      slot = 'no_slot_' .. self._sv.no_slot_counter
      self._sv.no_slot_counter = self._sv.no_slot_counter + 1
   end

   -- unequip previous item in slot first, then assign the item to the slot
   local unequipped_item = self._sv.equipped_items[slot]
   if unequipped_item then
      local also_unequipped = unequipped_item:get_component('stonehearth:equipment_piece'):get_additional_equipment()
      self:unequip_item(unequipped_item)
      if also_unequipped then
         for unequip_uri, _ in pairs(also_unequipped) do
            local old_item = self:unequip_item(unequip_uri, true) -- Paul: this extra parameter is the only change to this function
            if old_item then
               self:drop_item(old_item)
            end
         end
      end
   end

   local additional_equipment = ep:get_additional_equipment()
   if additional_equipment then
      for uri, should_equip in pairs(additional_equipment) do
         if should_equip then
            local old_item = self:equip_item(uri, false)
            if old_item then
               self:drop_item(old_item)
            end
         end
      end
   end

   self._sv.equipped_items[slot] = item

   ep:equip(self._entity)

   if destroy_old_item and unequipped_item then
      radiant.entities.destroy_entity(unequipped_item)
   end

   self.__saved_variables:mark_changed()
   self:_trigger_equipment_changed()

   return unequipped_item, item
end

-- takes an enity or a uri
function AceEquipmentComponent:unequip_item(equipped_item, replace_with_default)
   local uri

   if type(equipped_item) == 'string' then
      uri = equipped_item
   else
      uri = equipped_item:get_uri()
   end

   local unequipped_item
   for key, item in pairs(self._sv.equipped_items) do
      local item_uri = item:get_uri()

      if item_uri == uri then
         -- remove the item from the slot
         self._sv.equipped_items[key] = nil

         item:get_component('stonehearth:equipment_piece'):unequip()

         self.__saved_variables:mark_changed()
         self:_trigger_equipment_changed()

         unequipped_item = item
         break
      end
   end

   -- check if there's a default item for the slot that we want to replace it with
   local ep_data = radiant.entities.get_component_data(unequipped_item, 'stonehearth:equipment_piece')
   local slot = ep_data.slot
   if unequipped_item and slot then
      local default_item = self._sv.default_equipment[slot]
      if replace_with_default and default_item then
         self._sv.default_equipment[slot] = nil
         self:equip_item(default_item)
      elseif ep_data.no_drop and not default_item then
         -- if there is no default to replace with, save the uri of this item for this slot
         self._sv.default_equipment[slot] = uri
         self.__saved_variables:mark_changed()
      end
   end

   return unequipped_item
end

return AceEquipmentComponent
