local Point3 = _radiant.csg.Point3
local Entity = _radiant.om.Entity
local rng = _radiant.math.get_default_rng()

local FertilizeCropAdjacent = radiant.class()
FertilizeCropAdjacent.name = 'fertilize crop adjacent'
FertilizeCropAdjacent.does = 'stonehearth_ace:fertilize_crop_adjacent'
FertilizeCropAdjacent.args = {
   field_layer = Entity,      -- the field the crop is in
   location = Point3,           -- the offset of the crop in the field
}
FertilizeCropAdjacent.priority = 0

function FertilizeCropAdjacent:start_thinking(ai, entity, args)
   self._log = ai:get_log()
   self._entity = entity
   self._spawn_count = self:_get_num_to_increment(entity)

   self._farmer_field = args.field_layer:get_component('stonehearth:farmer_field_layer')
                                    :get_farmer_field()
   self._crop = self._farmer_field:crop_at(args.location)

   if not self._crop or not self._crop:is_valid() then
      self._log:detail('no crop at %s (%s)', offset, tostring(self._crop))
      return
   end

   local carrying = ai.CURRENT.carrying
   if not carrying or not self:_fertilizer_has_stacks(carrying) then
      return
   end

   self._origin = radiant.entities.get_world_grid_location(args.field_layer)
   self._location = args.location
   self._destination = args.field_layer:get_component('destination')

   ai:protect_argument(self._crop)
   ai:set_think_output();
end

function FertilizeCropAdjacent:_fertilize_one_time(ai, entity)
   assert(self._crop and self._crop:is_valid())

   local carrying = radiant.entities.get_carrying(entity)

   -- make sure we're carrying fertilizer with at least 1 use remaining
   if not carrying or not self:_fertilizer_has_stacks(carrying) then
      return false
   end

   -- all good!  fertilize once
   radiant.entities.turn_to_face(entity, self._crop)
   ai:execute('stonehearth:run_effect', { effect = 'fiddle' })

   -- determine quality value to apply based on fertilizer data
   local quality = self:_get_quality(carrying)
   if quality > 1 then
      self._crop:add_component('stonehearth:item_quality'):initialize_quality(quality, entity, nil, {override_allow_variable_quality = true})
   end

   radiant.entities.consume_stack(entity, 1)

   radiant.events.trigger_async(entity, 'stonehearth_ace:fertilize_crop', {crop_uri = self._crop:get_uri()})

   return true
end

function FertilizeCropAdjacent:run(ai, entity, args)
   self._log:detail('entering loop..')
   while self._crop and self._crop:is_valid() and self:_fertilize_one_time(ai, entity) do
      self:_unreserve_location()

      -- woot!  see if we can find another crop in
      self._log:detail('gimme more..')
      self:_move_to_next_available_crop(ai, entity, args)
   end

   self._log:detail('exited loop..')

   -- if there are more crops to be fertilized, we must've fun out of fertilizer, so we're done (let the ai rethink getting more)
end

function FertilizeCropAdjacent:stop(ai, entity, args)
   self:_unreserve_location()
end

function FertilizeCropAdjacent:_fertilizer_has_stacks(carrying)
   local stacks_component = carrying:get_component('stonehearth:stacks')
   if not stacks_component or stacks_component:get_stacks() < 1 then
      return false
   end
   return true
end

function FertilizeCropAdjacent:_get_quality(fertilizer)
   local quality_chances = radiant.entities.get_entity_data(fertilizer, 'stonehearth_ace:fertilizer').quality_chances
   local roll = rng:get_real(0, 1)
   local output_quality = 1

   local cumulative_chance = 0
   for _, value in ipairs(quality_chances) do
      local quality, chance = value[1], value[2]
      cumulative_chance = cumulative_chance + chance
      if (roll <= cumulative_chance) then
         output_quality = quality
         break
      end
   end

   return output_quality
end

function FertilizeCropAdjacent:_unreserve_location()
   if self._location then
      if self._destination:is_valid() then
         local block = self._location - self._origin
         self._destination:get_reserved():modify(function(cursor)
            cursor:subtract_point(block)
         end)
      end
      self._location = nil
   end
end

function FertilizeCropAdjacent:_move_to_next_available_crop(ai, entity, args)
   self._crop = nil

   -- see if there's a path to an unbuilt block on the same entity within 8 voxels
   local path = entity:get_component('stonehearth:pathfinder')
                           :find_path_to_entity_sync('find another crop to fertilize',
                                                     args.field_layer,
                                                     8)

   if path then
      local location = path:get_destination_point_of_interest()
      local reserved = self._destination:get_reserved()

      -- Pull the crop out of that location
      self._crop = args.field_layer:get_component('stonehearth:farmer_field_layer')
                                 :get_farmer_field()
                                    :crop_at(location)
      if not self._crop or not self._crop:is_valid() then
         return
      end

      -- reserve the crop so no one else grabs it
      local block = location - self._origin
      reserved:modify(function(cursor)
            cursor:add_point(block)
         end)

      -- remember the location so we can unreserve it later
      self._location = location

      -- follow the path.  this may go away for a while (which is why we had to reserve the
      -- block a few lines ago!)
      ai:execute('stonehearth:follow_path', { path = path })
   end
end

return FertilizeCropAdjacent