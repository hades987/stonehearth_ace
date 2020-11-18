local Plan = require 'stonehearth.components.building2.plan.plan'
local Fixture = require 'stonehearth.components.building2.fixture'
local FixtureData = require 'lib.building.fixture_data'
local BlueprintsToBuildingPiecesJob = require 'stonehearth.components.building2.plan.jobs.blueprints_to_building_pieces_job'
local BuildingCompletionJob = require 'stonehearth.components.building2.building_completion_job'

local Point3 = _radiant.csg.Point3
local Region3 = _radiant.csg.Region3
local Cube3   = _radiant.csg.Cube3
local Color4   = _radiant.csg.Color4

local NewStructureOp = require 'components.building2.new_structure_op'
local MutateOp = require 'components.building2.mutate_op'
local DeleteStructureOp = require 'components.building2.delete_structure_op'
local StartOp = radiant.class()
function StartOp:__init()
   self._name = 'start'
end


local VERSIONS = {
   KILL_LEVELS = 1,
}


local log = radiant.log.create_logger('build.building')

local Building = require 'stonehearth.components.building2.building'
local AceBuilding = class()

AceBuilding._ace_old_activate = Building.activate
function AceBuilding:activate(loading)
   if not self._sv._banked_resources then
      self._sv._banked_resources = {}
   end

   self._registered_materials_to_be_banked = {}
   self._registered_materials_by_entity = {}

   self:_ace_old_activate(loading)

   if self._sv.plan_job_status == stonehearth.constants.building.plan_job_status.COMPLETE then
      self:_create_resource_collection_tasks()
   end
end

AceBuilding._ace_old_pause_building = Building.pause_building
function AceBuilding:pause_building()
   local building_status = self:_ace_old_pause_building()
   radiant.events.trigger_async(self._entity, 'stonehearth_ace:building_paused')
   return building_status
end

AceBuilding._ace_old_resume_building = Building.resume_building
function AceBuilding:resume_building()
   local building_status = self:_ace_old_resume_building()
   radiant.events.trigger_async(self._entity, 'stonehearth_ace:building_resumed')
   return building_status
end

function AceBuilding:currently_building()
   return self:in_progress() and self._sv.building_status ~= stonehearth.constants.building.building_status.PAUSED
end

function AceBuilding:get_envelope_entity()
   return self._sv._envelope_entity
end

function AceBuilding:has_banked_resource(material)
   local banked = self._sv._banked_resources[material]
   return banked and banked.count > 0
end

function AceBuilding:get_remaining_resource_cost(entity)
   local remaining = self._sv.resource_cost
   if not next(remaining) then
      return remaining
   end
   
   -- if an entity is specified, ignore any materials registered to be banked by them
   local entity_id = entity and entity:get_id()
   local resources = {}
   for material, cost in pairs(remaining) do
      local amount = cost
      local registered = self._registered_materials_to_be_banked[material]
      if registered then
         for id, reg_amt in pairs(registered) do
            if id ~= entity_id then
               amount = amount - reg_amt
            end
         end
      end

      if amount > 0 then
         resources[material] = amount
      end
   end

   return resources
end

function AceBuilding:register_material_to_be_banked(entity, material, item)
   local entity_id = entity:get_id()
   local registered_material = self._registered_materials_to_be_banked[material]
   if not registered_material then
      registered_material = {}
      self._registered_materials_to_be_banked[material] = registered_material
   end

   if not registered_material[entity_id] then
      local stacks_comp = item:get_component('stonehearth:stacks')
      local stacks = stacks_comp and stacks_comp:get_stacks() or 1
      registered_material[entity_id] = stacks
      self._registered_materials_by_entity[entity_id] = material
      
      radiant.events.trigger_async(self._entity, 'stonehearth:build2:costs_changed')

      return true
   end
end

function AceBuilding:unregister_material_to_be_banked(entity_id, material)
   material = material or self._registered_materials_by_entity[entity_id]
   local registered_material = self._registered_materials_to_be_banked[material]
   if registered_material then
      registered_material[entity_id] = nil
   end
   self._registered_materials_by_entity[entity_id] = nil
end

function AceBuilding:try_bank_resource(item, material)
   -- if the material is a number, it's actually an entity_id; get the corresponding material
   if radiant.util.is_number(material) then
      material = self._registered_materials_by_entity[material]
   end
   
   -- only bank it if this resource is still required
   local remaining = self._sv.resource_cost[material]
   if remaining then
      local banked = self._sv._banked_resources[material]
      if not banked then
         banked = {
            count = 0,
            quality = 0,
            quality_count = 0,
         }
         self._sv._banked_resources[material] = banked
      end

      local stacks_comp = item:get_component('stonehearth:stacks')
      local stacks = stacks_comp and stacks_comp:get_stacks() or 1
      banked.count = banked.count + stacks
      -- storing quality weighted by count; TODO: when the building is completed, total overall quality can then be evaluated
      banked.quality_count = banked.quality_count + stacks
      banked.quality = banked.quality + stacks * radiant.entities.get_item_quality(item)

      remaining = remaining - stacks
      if remaining <= 0 then
         self._sv.resource_cost[material] = nil
      else
         self._sv.resource_cost[material] = remaining
      end
      self.__saved_variables:mark_changed()

      -- technically possible for a slightly negative banked count to then have only 1-2 stacks of a resource banked
      if banked.count > 0 then
         radiant.events.trigger_async(self._entity, 'stonehearth_ace:material_resource_banked', material)
      end

      return true
   end
end

function AceBuilding:spend_banked_resource(material, amount)
   local banked = self._sv._banked_resources[material]
   if banked then
      -- no need for a 0 check, it can go negative since it's the overall total for completing the building
      -- but isn't fully supplied upfront
      banked.count = banked.count - amount
   end
end

function AceBuilding:get_building_quality()
   local quality, count = 0, 0
   for _, resource in pairs(self._sv._banked_resources) do
      quality = quality + resource.quality
      count = count + resource.quality_count
   end

   if count > 0 then
      quality = quality / count
   else
      quality = 1
   end
   log:debug('%s current building quality: %s', self._entity, quality)
end

AceBuilding._ace_old__calculate_remaining_resource_cost = Building._calculate_remaining_resource_cost
function AceBuilding:_calculate_remaining_resource_cost()
   self:_ace_old__calculate_remaining_resource_cost()

   local remaining = self._sv.resource_cost
   for mat, resource in pairs(self._sv._banked_resources) do
      if remaining[mat] then
         remaining[mat] = remaining[mat] - resource.count
         if remaining[mat] < 1 then
            remaining[mat] = nil
         end
      end
   end
   self.__saved_variables:mark_changed()
end

AceBuilding._ace_old__on_building_start = Building._on_building_start
function AceBuilding:_on_building_start(plan, envelope_w, root_point, terrain_region_w)
   self:_ace_old__on_building_start(plan, envelope_w, root_point, terrain_region_w)

   self._sv._envelope_entity:get_component('destination'):set_auto_update_adjacent(true)
   self:_create_resource_collection_tasks()
end

AceBuilding._ace_old__on_plan_complete = Building._on_plan_complete
function AceBuilding:_on_plan_complete()
   self:_destroy_resource_collection_tasks()
   self:_ace_old__on_plan_complete()
end

function AceBuilding:_create_resource_collection_tasks()
   self:_calculate_remaining_resource_cost()
   stonehearth.town:get_town(self._entity:get_player_id()):create_resource_collection_tasks(self._entity, self._sv.resource_cost)
end

function AceBuilding:_destroy_resource_collection_tasks()
   stonehearth.town:get_town(self._entity:get_player_id()):destroy_resource_collection_tasks(self._entity)
end

return AceBuilding
