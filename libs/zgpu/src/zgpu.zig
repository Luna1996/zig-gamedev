const std = @import("std");
const assert = std.debug.assert;
const glfw = @import("glfw");
const c = @cImport({
    @cInclude("dawn/dawn_proc.h");
    @cInclude("dawn_native_mach.h");
});
const objc = @cImport({
    @cInclude("objc/message.h");
});
pub const cimgui = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "");
    @cDefine("CIMGUI_NO_EXPORT", "");
    @cInclude("imgui/cimgui.h");
});
pub const gpu = @import("mach-gpu/main.zig");
const wgsl = @import("common_wgsl.zig");

pub const GraphicsContext = struct {
    native_instance: gpu.NativeInstance,
    adapter_type: gpu.Adapter.Type,
    backend_type: gpu.Adapter.BackendType,
    device: gpu.Device,
    queue: gpu.Queue,
    window: glfw.Window,
    window_surface: gpu.Surface,
    swapchain: gpu.SwapChain,
    swapchain_descriptor: gpu.SwapChain.Descriptor,
    stats: FrameStats = .{},

    buffer_pool: BufferPool,
    texture_pool: TexturePool,
    texture_view_pool: TextureViewPool,
    sampler_pool: SamplerPool,
    render_pipeline_pool: RenderPipelinePool,
    compute_pipeline_pool: ComputePipelinePool,
    bind_group_pool: BindGroupPool,
    bind_group_layout_pool: BindGroupLayoutPool,
    pipeline_layout_pool: PipelineLayoutPool,

    uniforms: struct {
        offset: u32 = 0,
        buffer: BufferHandle = .{},
        stage: struct {
            num: u32 = 0,
            current: u32 = 0,
            buffers: [uniforms_staging_pipeline_len]UniformsStagingBuffer =
                [_]UniformsStagingBuffer{.{}} ** uniforms_staging_pipeline_len,
        } = .{},
    } = .{},

    mipgen: struct {
        pipeline: ComputePipelineHandle = .{},
        scratch_texture: TextureHandle = .{},
        scratch_texture_views: [4]TextureViewHandle = [_]TextureViewHandle{.{}} ** 4,
        bind_group_layout: BindGroupLayoutHandle = .{},
    } = .{},

    pub const swapchain_format = gpu.Texture.Format.bgra8_unorm;

    // TODO: Adjust pool sizes.
    const buffer_pool_size = 256;
    const texture_pool_size = 256;
    const texture_view_pool_size = 256;
    const sampler_pool_size = 16;
    const render_pipeline_pool_size = 128;
    const compute_pipeline_pool_size = 128;
    const bind_group_pool_size = 32;
    const bind_group_layout_pool_size = 32;
    const pipeline_layout_pool_size = 32;

    pub fn init(allocator: std.mem.Allocator, window: glfw.Window) !*GraphicsContext {
        c.dawnProcSetProcs(c.machDawnNativeGetProcs());
        const instance = c.machDawnNativeInstance_init();
        c.machDawnNativeInstance_discoverDefaultAdapters(instance);

        var native_instance = gpu.NativeInstance.wrap(c.machDawnNativeInstance_get(instance).?);

        const gpu_interface = native_instance.interface();
        const backend_adapter = switch (gpu_interface.waitForAdapter(&.{
            .power_preference = .high_performance,
        })) {
            .adapter => |v| v,
            .err => |err| {
                std.debug.print("[zgpu] Failed to get adapter: error={} {s}\n", .{ err.code, err.message });
                return error.NoGraphicsAdapter;
            },
        };

        const props = backend_adapter.properties;
        std.debug.print("[zgpu] High-performance device has been selected:\n", .{});
        std.debug.print("[zgpu]   Name: {s}\n", .{props.name});
        std.debug.print("[zgpu]   Driver: {s}\n", .{props.driver_description});
        std.debug.print("[zgpu]   Adapter type: {s}\n", .{gpu.Adapter.typeName(props.adapter_type)});
        std.debug.print("[zgpu]   Backend type: {s}\n", .{gpu.Adapter.backendTypeName(props.backend_type)});

        const device = switch (backend_adapter.waitForDevice(&.{})) {
            .device => |v| v,
            .err => |err| {
                std.debug.print("[zgpu] Failed to get device: error={} {s}\n", .{ err.code, err.message });
                return error.NoGraphicsDevice;
            },
        };
        device.setUncapturedErrorCallback(&printUnhandledErrorCallback);

        const window_surface = createSurfaceForWindow(
            &native_instance,
            window,
            comptime detectGLFWOptions(),
        );
        const framebuffer_size = window.getFramebufferSize() catch unreachable;

        const swapchain_descriptor = gpu.SwapChain.Descriptor{
            .label = "main window swap chain",
            .usage = .{ .render_attachment = true },
            .format = swapchain_format,
            .width = framebuffer_size.width,
            .height = framebuffer_size.height,
            .present_mode = .fifo,
            .implementation = 0,
        };
        const swapchain = device.nativeCreateSwapChain(
            window_surface,
            &swapchain_descriptor,
        );

        const gctx = allocator.create(GraphicsContext) catch unreachable;
        gctx.* = .{
            .native_instance = native_instance,
            .adapter_type = props.adapter_type,
            .backend_type = props.backend_type,
            .device = device,
            .queue = device.getQueue(),
            .window = window,
            .window_surface = window_surface,
            .swapchain = swapchain,
            .swapchain_descriptor = swapchain_descriptor,
            .buffer_pool = BufferPool.init(allocator, buffer_pool_size),
            .texture_pool = TexturePool.init(allocator, texture_pool_size),
            .texture_view_pool = TextureViewPool.init(allocator, texture_view_pool_size),
            .sampler_pool = SamplerPool.init(allocator, sampler_pool_size),
            .render_pipeline_pool = RenderPipelinePool.init(allocator, render_pipeline_pool_size),
            .compute_pipeline_pool = ComputePipelinePool.init(allocator, compute_pipeline_pool_size),
            .bind_group_pool = BindGroupPool.init(allocator, bind_group_pool_size),
            .bind_group_layout_pool = BindGroupLayoutPool.init(allocator, bind_group_layout_pool_size),
            .pipeline_layout_pool = PipelineLayoutPool.init(allocator, pipeline_layout_pool_size),
        };

        gctx.queue.on_submitted_work_done = gpu.Queue.WorkDoneCallback.init(
            *u64,
            &gctx.stats.gpu_frame_number,
            gpuWorkDone,
        );

        uniformsInit(gctx);
        return gctx;
    }

    pub fn deinit(gctx: *GraphicsContext, allocator: std.mem.Allocator) void {
        // TODO: How to release `native_instance`?

        // Wait for the GPU to finish all encoded commands.
        while (gctx.stats.cpu_frame_number != gctx.stats.gpu_frame_number) {
            gctx.device.tick();
        }

        // Wait for all outstanding mapAsync() calls to complete.
        wait_loop: while (true) {
            gctx.device.tick();
            var i: u32 = 0;
            while (i < gctx.uniforms.stage.num) : (i += 1) {
                if (gctx.uniforms.stage.buffers[i].slice == null) {
                    continue :wait_loop;
                }
            }
            break;
        }

        gctx.pipeline_layout_pool.deinit(allocator);
        gctx.bind_group_pool.deinit(allocator);
        gctx.bind_group_layout_pool.deinit(allocator);
        gctx.buffer_pool.deinit(allocator);
        gctx.texture_view_pool.deinit(allocator);
        gctx.texture_pool.deinit(allocator);
        gctx.sampler_pool.deinit(allocator);
        gctx.render_pipeline_pool.deinit(allocator);
        gctx.compute_pipeline_pool.deinit(allocator);
        gctx.window_surface.release();
        gctx.swapchain.release();
        gctx.queue.release();
        gctx.device.release();
        allocator.destroy(gctx);
    }

    //
    // Uniform buffer pool
    //
    pub fn uniformsAllocate(
        gctx: *GraphicsContext,
        comptime T: type,
        num_elements: u32,
    ) struct { slice: []T, offset: u32 } {
        assert(num_elements > 0);
        const size = num_elements * @sizeOf(T);

        const offset = gctx.uniforms.offset;
        const aligned_size = (size + (uniforms_alloc_alignment - 1)) & ~(uniforms_alloc_alignment - 1);
        if ((offset + aligned_size) >= uniforms_buffer_size) {
            // TODO: Better error handling; pool is full; flush it?
            return .{ .slice = @as([*]T, undefined)[0..0], .offset = 0 };
        }

        const current = gctx.uniforms.stage.current;
        const slice = (gctx.uniforms.stage.buffers[current].slice.?.ptr + offset)[0..size];

        gctx.uniforms.offset += aligned_size;
        return .{
            .slice = std.mem.bytesAsSlice(T, @alignCast(@alignOf(T), slice)),
            .offset = offset,
        };
    }

    const UniformsStagingBuffer = struct {
        slice: ?[]u8 = null,
        buffer: gpu.Buffer = undefined,
        callback: gpu.Buffer.MapCallback = undefined,
    };
    const uniforms_buffer_size = 4 * 1024 * 1024;
    const uniforms_staging_pipeline_len = 8;
    const uniforms_alloc_alignment: u32 = 256;

    fn uniformsInit(gctx: *GraphicsContext) void {
        gctx.uniforms.buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .uniform = true },
            .size = uniforms_buffer_size,
        });
        gctx.uniformsNextStagingBuffer();
    }

    fn uniformsMappedCallback(usb: *UniformsStagingBuffer, status: gpu.Buffer.MapAsyncStatus) void {
        assert(usb.slice == null);
        if (status == .success) {
            usb.slice = usb.buffer.getMappedRange(u8, 0, uniforms_buffer_size);
        } else {
            std.debug.print("[zgpu] Failed to map buffer (code: {d})\n", .{@enumToInt(status)});
        }
    }

    fn uniformsNextStagingBuffer(gctx: *GraphicsContext) void {
        if (gctx.stats.cpu_frame_number > 0) {
            // Map staging buffer which was used this frame.
            const current = gctx.uniforms.stage.current;
            assert(gctx.uniforms.stage.buffers[current].slice == null);
            gctx.uniforms.stage.buffers[current].buffer.mapAsync(
                .write,
                0,
                uniforms_buffer_size,
                &gctx.uniforms.stage.buffers[current].callback,
            );
        }

        gctx.uniforms.offset = 0;

        var i: u32 = 0;
        while (i < gctx.uniforms.stage.num) : (i += 1) {
            if (gctx.uniforms.stage.buffers[i].slice != null) {
                gctx.uniforms.stage.current = i;
                return;
            }
        }

        if (gctx.uniforms.stage.num >= uniforms_staging_pipeline_len) {
            // Wait until one of the buffers is mapped and ready to use.
            while (true) {
                gctx.device.tick();

                i = 0;
                while (i < gctx.uniforms.stage.num) : (i += 1) {
                    if (gctx.uniforms.stage.buffers[i].slice != null) {
                        gctx.uniforms.stage.current = i;
                        return;
                    }
                }
            }
        }

        assert(gctx.uniforms.stage.num < uniforms_staging_pipeline_len);
        const current = gctx.uniforms.stage.num;
        gctx.uniforms.stage.current = current;
        gctx.uniforms.stage.num += 1;

        // Create new staging buffer.
        const buffer_handle = gctx.createBuffer(.{
            .usage = .{ .copy_src = true, .map_write = true },
            .size = uniforms_buffer_size,
            .mapped_at_creation = true,
        });

        // Add new (mapped) staging buffer to the buffer list.
        gctx.uniforms.stage.buffers[current] = .{
            .slice = gctx.lookupResource(buffer_handle).?.getMappedRange(u8, 0, uniforms_buffer_size),
            .buffer = gctx.lookupResource(buffer_handle).?,
            .callback = gpu.Buffer.MapCallback.init(
                *UniformsStagingBuffer,
                &gctx.uniforms.stage.buffers[current],
                uniformsMappedCallback,
            ),
        };
    }

    //
    // Submit
    //
    pub fn submitAndPresent(gctx: *GraphicsContext, commands: []const gpu.CommandBuffer) enum {
        nothing_special_happened,
        swap_chain_resized,
    } {
        const stage_commands = stage_commands: {
            const stage_encoder = gctx.device.createCommandEncoder(null);
            defer stage_encoder.release();

            const current = gctx.uniforms.stage.current;
            assert(gctx.uniforms.stage.buffers[current].slice != null);

            gctx.uniforms.stage.buffers[current].slice = null;
            gctx.uniforms.stage.buffers[current].buffer.unmap();

            if (gctx.uniforms.offset > 0) {
                stage_encoder.copyBufferToBuffer(
                    gctx.uniforms.stage.buffers[current].buffer,
                    0,
                    gctx.lookupResource(gctx.uniforms.buffer).?,
                    0,
                    gctx.uniforms.offset,
                );
            }

            break :stage_commands stage_encoder.finish(null);
        };
        defer stage_commands.release();

        // TODO: We support up to 32 command buffers for now. Make it more robust.
        var command_buffers = std.BoundedArray(gpu.CommandBuffer, 32).init(0) catch unreachable;
        command_buffers.append(stage_commands) catch unreachable;
        command_buffers.appendSlice(commands) catch unreachable;
        gctx.queue.submit(command_buffers.slice());

        gctx.stats.tick();
        gctx.uniformsNextStagingBuffer();

        gctx.swapchain.present();

        const fb_size = gctx.window.getFramebufferSize() catch unreachable;
        if (gctx.swapchain_descriptor.width != fb_size.width or
            gctx.swapchain_descriptor.height != fb_size.height)
        {
            gctx.swapchain_descriptor.width = fb_size.width;
            gctx.swapchain_descriptor.height = fb_size.height;
            gctx.swapchain.release();
            gctx.swapchain = gctx.device.nativeCreateSwapChain(
                gctx.window_surface,
                &gctx.swapchain_descriptor,
            );

            std.debug.print(
                "[zgpu] Window has been resized to: {d}x{d}\n",
                .{ gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height },
            );
            return .swap_chain_resized;
        }
        return .nothing_special_happened;
    }

    fn gpuWorkDone(gpu_frame_number: *u64, status: gpu.Queue.WorkDoneStatus) void {
        gpu_frame_number.* += 1;
        if (status != .success) {
            std.debug.print("[zgpu] Failed to complete GPU work (code: {d})\n", .{@enumToInt(status)});
        }
    }

    //
    // Resources
    //
    pub fn createBuffer(gctx: *GraphicsContext, descriptor: gpu.Buffer.Descriptor) BufferHandle {
        return gctx.buffer_pool.addResource(gctx.*, .{
            .gpuobj = gctx.device.createBuffer(&descriptor),
            .size = descriptor.size,
            .usage = descriptor.usage,
        });
    }

    pub fn createTexture(gctx: *GraphicsContext, descriptor: gpu.Texture.Descriptor) TextureHandle {
        return gctx.texture_pool.addResource(gctx.*, .{
            .gpuobj = gctx.device.createTexture(&descriptor),
            .usage = descriptor.usage,
            .dimension = descriptor.dimension,
            .size = descriptor.size,
            .format = descriptor.format,
            .mip_level_count = descriptor.mip_level_count,
            .sample_count = descriptor.sample_count,
        });
    }

    pub fn createTextureView(
        gctx: *GraphicsContext,
        texture_handle: TextureHandle,
        descriptor: gpu.TextureView.Descriptor,
    ) TextureViewHandle {
        const texture = gctx.lookupResource(texture_handle).?;
        const info = gctx.lookupResourceInfo(texture_handle).?;
        return gctx.texture_view_pool.addResource(gctx.*, .{
            .gpuobj = texture.createView(&descriptor),
            .format = if (descriptor.format == .none) info.format else descriptor.format,
            .dimension = if (descriptor.dimension == .dimension_none)
                @intToEnum(gpu.TextureView.Dimension, @enumToInt(info.dimension))
            else
                descriptor.dimension,
            .base_mip_level = descriptor.base_mip_level,
            .mip_level_count = if (descriptor.mip_level_count == 0xffff_ffff)
                info.mip_level_count
            else
                descriptor.mip_level_count,
            .base_array_layer = descriptor.base_array_layer,
            .array_layer_count = if (descriptor.array_layer_count == 0xffff_ffff)
                info.size.depth_or_array_layers
            else
                descriptor.array_layer_count,
            .aspect = descriptor.aspect,
            .parent_texture_handle = texture_handle,
        });
    }

    pub fn createSampler(gctx: *GraphicsContext, descriptor: gpu.Sampler.Descriptor) SamplerHandle {
        return gctx.sampler_pool.addResource(gctx.*, .{
            .gpuobj = gctx.device.createSampler(&descriptor),
            .address_mode_u = descriptor.address_mode_u,
            .address_mode_v = descriptor.address_mode_v,
            .address_mode_w = descriptor.address_mode_w,
            .mag_filter = descriptor.mag_filter,
            .min_filter = descriptor.min_filter,
            .mipmap_filter = descriptor.mipmap_filter,
            .lod_min_clamp = descriptor.lod_min_clamp,
            .lod_max_clamp = descriptor.lod_max_clamp,
            .compare = descriptor.compare,
            .max_anisotropy = descriptor.max_anisotropy,
        });
    }

    pub fn createRenderPipeline(
        gctx: *GraphicsContext,
        pipeline_layout: PipelineLayoutHandle,
        descriptor: gpu.RenderPipeline.Descriptor,
    ) RenderPipelineHandle {
        var desc = descriptor;
        desc.layout = gctx.lookupResource(pipeline_layout) orelse null;
        return gctx.render_pipeline_pool.addResource(gctx.*, .{
            .gpuobj = gctx.device.createRenderPipeline(&desc),
            .pipeline_layout_handle = pipeline_layout,
        });
    }

    const AsyncCreateOpRender = struct {
        gctx: *GraphicsContext,
        result: *RenderPipelineHandle,
        pipeline_layout: PipelineLayoutHandle,
        callback: gpu.RenderPipeline.CreateCallback,
        allocator: std.mem.Allocator,

        fn create(
            op: *AsyncCreateOpRender,
            status: gpu.RenderPipeline.CreateStatus,
            pipeline: gpu.RenderPipeline,
            message: [:0]const u8,
        ) void {
            if (status == .success) {
                op.result.* = op.gctx.render_pipeline_pool.addResource(
                    op.gctx.*,
                    .{ .gpuobj = pipeline, .pipeline_layout_handle = op.pipeline_layout },
                );
            } else {
                std.debug.print(
                    "[zgpu] Failed to async create render pipeline (code: {d})\n{s}\n",
                    .{ status, message },
                );
            }
            op.allocator.destroy(op);
        }
    };

    pub fn createRenderPipelineAsync(
        gctx: *GraphicsContext,
        allocator: std.mem.Allocator,
        pipeline_layout: PipelineLayoutHandle,
        descriptor: gpu.RenderPipeline.Descriptor,
        result: *RenderPipelineHandle,
    ) void {
        var desc = descriptor;
        desc.layout = gctx.lookupResource(pipeline_layout) orelse null;

        const op = allocator.create(AsyncCreateOpRender) catch unreachable;
        op.* = .{
            .gctx = gctx,
            .result = result,
            .pipeline_layout = pipeline_layout,
            .callback = gpu.RenderPipeline.CreateCallback.init(
                *AsyncCreateOpRender,
                op,
                AsyncCreateOpRender.create,
            ),
            .allocator = allocator,
        };
        gctx.device.createRenderPipelineAsync(&desc, &op.callback);
    }

    pub fn createComputePipeline(
        gctx: *GraphicsContext,
        pipeline_layout: PipelineLayoutHandle,
        descriptor: gpu.ComputePipeline.Descriptor,
    ) ComputePipelineHandle {
        var desc = descriptor;
        desc.layout = gctx.lookupResource(pipeline_layout) orelse null;
        return gctx.compute_pipeline_pool.addResource(gctx.*, .{
            .gpuobj = gctx.device.createComputePipeline(&desc),
            .pipeline_layout_handle = pipeline_layout,
        });
    }

    const AsyncCreateOpCompute = struct {
        gctx: *GraphicsContext,
        result: *ComputePipelineHandle,
        pipeline_layout: PipelineLayoutHandle,
        callback: gpu.ComputePipeline.CreateCallback,
        allocator: std.mem.Allocator,

        fn create(
            op: *AsyncCreateOpCompute,
            status: gpu.ComputePipeline.CreateStatus,
            pipeline: gpu.ComputePipeline,
            message: [:0]const u8,
        ) void {
            if (status == .success) {
                op.result.* = op.gctx.compute_pipeline_pool.addResource(
                    op.gctx.*,
                    .{ .gpuobj = pipeline, .pipeline_layout_handle = op.pipeline_layout },
                );
            } else {
                std.debug.print(
                    "[zgpu] Failed to async create compute pipeline (code: {d})\n{s}\n",
                    .{ status, message },
                );
            }
            op.allocator.destroy(op);
        }
    };

    pub fn createComputePipelineAsync(
        gctx: *GraphicsContext,
        allocator: std.mem.Allocator,
        pipeline_layout: PipelineLayoutHandle,
        descriptor: gpu.ComputePipeline.Descriptor,
        result: *ComputePipelineHandle,
    ) void {
        var desc = descriptor;
        desc.layout = gctx.lookupResource(pipeline_layout) orelse null;

        const op = allocator.create(AsyncCreateOpCompute) catch unreachable;
        op.* = .{
            .gctx = gctx,
            .result = result,
            .pipeline_layout = pipeline_layout,
            .callback = gpu.ComputePipeline.CreateCallback.init(
                *AsyncCreateOpCompute,
                op,
                AsyncCreateOpCompute.create,
            ),
            .allocator = allocator,
        };
        gctx.device.createComputePipelineAsync(&desc, &op.callback);
    }

    pub fn createBindGroup(
        gctx: *GraphicsContext,
        layout: BindGroupLayoutHandle,
        entries: []const BindGroupEntryInfo,
    ) BindGroupHandle {
        assert(entries.len > 0 and entries.len < max_num_bindings_per_group);

        var bind_group_info = BindGroupInfo{ .num_entries = @intCast(u32, entries.len) };
        var gpu_bind_group_entries: [max_num_bindings_per_group]gpu.BindGroup.Entry = undefined;

        for (entries) |entry, i| {
            bind_group_info.entries[i] = entry;

            if (entries[i].buffer_handle) |handle| {
                gpu_bind_group_entries[i] = .{
                    .binding = entries[i].binding,
                    .buffer = gctx.lookupResource(handle).?,
                    .offset = entries[i].offset,
                    .size = entries[i].size,
                    .sampler = null,
                    .texture_view = null,
                };
            } else if (entries[i].sampler_handle) |handle| {
                gpu_bind_group_entries[i] = .{
                    .binding = entries[i].binding,
                    .buffer = null,
                    .offset = 0,
                    .size = 0,
                    .sampler = gctx.lookupResource(handle).?,
                    .texture_view = null,
                };
            } else if (entries[i].texture_view_handle) |handle| {
                gpu_bind_group_entries[i] = .{
                    .binding = entries[i].binding,
                    .buffer = null,
                    .offset = 0,
                    .size = 0,
                    .sampler = null,
                    .texture_view = gctx.lookupResource(handle).?,
                };
            } else unreachable;
        }
        bind_group_info.gpuobj = gctx.device.createBindGroup(&.{
            .layout = gctx.lookupResource(layout).?,
            .entries = gpu_bind_group_entries[0..entries.len],
        });
        return gctx.bind_group_pool.addResource(gctx.*, bind_group_info);
    }

    pub fn createBindGroupLayout(
        gctx: *GraphicsContext,
        entries: []const gpu.BindGroupLayout.Entry,
    ) BindGroupLayoutHandle {
        assert(entries.len > 0 and entries.len < max_num_bindings_per_group);

        var bind_group_layout_info = BindGroupLayoutInfo{
            .gpuobj = gctx.device.createBindGroupLayout(&.{ .entries = entries }),
            .num_entries = @intCast(u32, entries.len),
        };
        for (entries) |entry, i| {
            bind_group_layout_info.entries[i] = entry;
            bind_group_layout_info.entries[i].reserved = null;
            bind_group_layout_info.entries[i].buffer.reserved = null;
            bind_group_layout_info.entries[i].sampler.reserved = null;
            bind_group_layout_info.entries[i].texture.reserved = null;
            bind_group_layout_info.entries[i].storage_texture.reserved = null;
        }
        return gctx.bind_group_layout_pool.addResource(gctx.*, bind_group_layout_info);
    }

    pub fn createBindGroupLayoutAuto(
        gctx: *GraphicsContext,
        pipeline: anytype,
        group_index: u32,
    ) BindGroupLayoutHandle {
        const bgl = gctx.lookupResource(pipeline).?.getBindGroupLayout(group_index);
        return gctx.bind_group_layout_pool.addResource(gctx.*, BindGroupLayoutInfo{ .gpuobj = bgl });
    }

    pub fn createPipelineLayout(
        gctx: *GraphicsContext,
        bind_group_layouts: []const BindGroupLayoutHandle,
    ) PipelineLayoutHandle {
        assert(bind_group_layouts.len > 0);

        var info: PipelineLayoutInfo = .{ .num_bind_group_layouts = @intCast(u32, bind_group_layouts.len) };
        var gpu_bind_group_layouts: [max_num_bind_groups_per_pipeline]gpu.BindGroupLayout = undefined;

        for (bind_group_layouts) |bgl, i| {
            info.bind_group_layouts[i] = bgl;
            gpu_bind_group_layouts[i] = gctx.lookupResource(bgl).?;
        }

        info.gpuobj = gctx.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor{
            .bind_group_layouts = gpu_bind_group_layouts[0..info.num_bind_group_layouts],
        });

        return gctx.pipeline_layout_pool.addResource(gctx.*, info);
    }

    pub fn lookupResource(gctx: GraphicsContext, handle: anytype) ?handleToGpuResourceType(@TypeOf(handle)) {
        if (gctx.isResourceValid(handle)) {
            const T = @TypeOf(handle);
            return switch (T) {
                BufferHandle => gctx.buffer_pool.resources[handle.index].gpuobj.?,
                TextureHandle => gctx.texture_pool.resources[handle.index].gpuobj.?,
                TextureViewHandle => gctx.texture_view_pool.resources[handle.index].gpuobj.?,
                SamplerHandle => gctx.sampler_pool.resources[handle.index].gpuobj.?,
                RenderPipelineHandle => gctx.render_pipeline_pool.resources[handle.index].gpuobj.?,
                ComputePipelineHandle => gctx.compute_pipeline_pool.resources[handle.index].gpuobj.?,
                BindGroupHandle => gctx.bind_group_pool.resources[handle.index].gpuobj.?,
                BindGroupLayoutHandle => gctx.bind_group_layout_pool.resources[handle.index].gpuobj.?,
                PipelineLayoutHandle => gctx.pipeline_layout_pool.resources[handle.index].gpuobj.?,
                else => @compileError(
                    "[zgpu] GraphicsContext.lookupResource() not implemented for " ++ @typeName(T),
                ),
            };
        }
        return null;
    }

    pub fn lookupResourceInfo(gctx: GraphicsContext, handle: anytype) ?handleToResourceInfoType(@TypeOf(handle)) {
        if (gctx.isResourceValid(handle)) {
            const T = @TypeOf(handle);
            return switch (T) {
                BufferHandle => gctx.buffer_pool.resources[handle.index],
                TextureHandle => gctx.texture_pool.resources[handle.index],
                TextureViewHandle => gctx.texture_view_pool.resources[handle.index],
                SamplerHandle => gctx.sampler_pool.resources[handle.index],
                RenderPipelineHandle => gctx.render_pipeline_pool.resources[handle.index],
                ComputePipelineHandle => gctx.compute_pipeline_pool.resources[handle.index],
                BindGroupHandle => gctx.bind_group_pool.resources[handle.index],
                BindGroupLayoutHandle => gctx.bind_group_layout_pool.resources[handle.index],
                PipelineLayoutHandle => gctx.pipeline_layout_pool.resources[handle.index],
                else => @compileError(
                    "[zgpu] GraphicsContext.lookupResourceInfo() not implemented for " ++ @typeName(T),
                ),
            };
        }
        return null;
    }

    pub fn destroyResource(gctx: GraphicsContext, handle: anytype) void {
        const T = @TypeOf(handle);
        switch (T) {
            BufferHandle => gctx.buffer_pool.destroyResource(handle),
            TextureHandle => gctx.texture_pool.destroyResource(handle),
            TextureViewHandle => gctx.texture_view_pool.destroyResource(handle),
            SamplerHandle => gctx.sampler_pool.destroyResource(handle),
            RenderPipelineHandle => gctx.render_pipeline_pool.destroyResource(handle),
            ComputePipelineHandle => gctx.compute_pipeline_pool.destroyResource(handle),
            BindGroupHandle => gctx.bind_group_pool.destroyResource(handle),
            BindGroupLayoutHandle => gctx.bind_group_layout_pool.destroyResource(handle),
            PipelineLayoutHandle => gctx.pipeline_layout_pool.destroyResource(handle),
            else => @compileError("[zgpu] GraphicsContext.destroyResource() not implemented for " ++ @typeName(T)),
        }
    }

    pub fn isResourceValid(gctx: GraphicsContext, handle: anytype) bool {
        const T = @TypeOf(handle);
        switch (T) {
            BufferHandle => return gctx.buffer_pool.isHandleValid(handle),
            TextureHandle => return gctx.texture_pool.isHandleValid(handle),
            TextureViewHandle => {
                if (gctx.texture_view_pool.isHandleValid(handle)) {
                    const texture = gctx.texture_view_pool.resources[handle.index].parent_texture_handle;
                    return gctx.isResourceValid(texture);
                }
                return false;
            },
            SamplerHandle => return gctx.sampler_pool.isHandleValid(handle),
            RenderPipelineHandle => return gctx.render_pipeline_pool.isHandleValid(handle),
            ComputePipelineHandle => return gctx.compute_pipeline_pool.isHandleValid(handle),
            BindGroupHandle => {
                if (gctx.bind_group_pool.isHandleValid(handle)) {
                    const num_entries = gctx.bind_group_pool.resources[handle.index].num_entries;
                    const entries = &gctx.bind_group_pool.resources[handle.index].entries;
                    var i: u32 = 0;
                    while (i < num_entries) : (i += 1) {
                        if (entries[i].buffer_handle) |buffer| {
                            if (!gctx.isResourceValid(buffer))
                                return false;
                        } else if (entries[i].sampler_handle) |sampler| {
                            if (!gctx.isResourceValid(sampler))
                                return false;
                        } else if (entries[i].texture_view_handle) |texture_view| {
                            if (!gctx.isResourceValid(texture_view))
                                return false;
                        } else unreachable;
                    }
                    return true;
                }
                return false;
            },
            BindGroupLayoutHandle => return gctx.bind_group_layout_pool.isHandleValid(handle),
            PipelineLayoutHandle => return gctx.pipeline_layout_pool.isHandleValid(handle),
            else => @compileError("[zgpu] GraphicsContext.isResourceValid() not implemented for " ++ @typeName(T)),
        }
    }

    //
    // Mipmaps
    //
    pub fn generateMipmaps(
        gctx: *GraphicsContext,
        encoder: gpu.CommandEncoder,
        texture: TextureHandle,
    ) void {
        const texture_info = gctx.lookupResourceInfo(texture) orelse return;
        if (texture_info.dimension != .dimension_2d) {
            // TODO: Print message.
            return;
        }

        if (!gctx.isResourceValid(gctx.mipgen.pipeline)) {
            gctx.mipgen.bind_group_layout = gctx.createBindGroupLayout(&.{
                bglBuffer(0, .{ .compute = true }, .uniform, true, 0),
                bglTexture(1, .{ .compute = true }, .float, .dimension_2d, false),
                bglStorageTexture(2, .{ .compute = true }, .write_only, .rgba8_unorm, .dimension_2d),
                bglStorageTexture(3, .{ .compute = true }, .write_only, .rgba8_unorm, .dimension_2d),
                bglStorageTexture(4, .{ .compute = true }, .write_only, .rgba8_unorm, .dimension_2d),
                bglStorageTexture(5, .{ .compute = true }, .write_only, .rgba8_unorm, .dimension_2d),
            });

            const pipeline_layout = gctx.createPipelineLayout(&.{
                gctx.mipgen.bind_group_layout,
            });
            defer gctx.destroyResource(pipeline_layout);

            const cs_module = gctx.device.createShaderModule(&.{
                .code = .{ .wgsl = wgsl.cs_generate_mipmaps },
            });
            defer cs_module.release();

            gctx.mipgen.pipeline = gctx.createComputePipeline(pipeline_layout, .{
                .compute = .{
                    .label = "zgpu_cs_generate_mipmaps",
                    .module = cs_module,
                    .entry_point = "main",
                },
            });

            gctx.mipgen.scratch_texture = gctx.createTexture(.{
                .usage = .{ .copy_src = true, .storage_binding = true },
                .dimension = .dimension_2d,
                .size = .{ .width = 1024, .height = 1024, .depth_or_array_layers = 1 },
                .format = .rgba8_unorm,
                .mip_level_count = 4,
                .sample_count = 1,
            });

            for (gctx.mipgen.scratch_texture_views) |*view, i| {
                view.* = gctx.createTextureView(gctx.mipgen.scratch_texture, .{
                    .base_mip_level = @intCast(u32, i),
                    .mip_level_count = 1,
                    .base_array_layer = 0,
                    .array_layer_count = 1,
                });
            }
        }

        const texture_view = gctx.createTextureView(texture, .{});
        defer gctx.destroyResource(texture_view);

        const bind_group = gctx.createBindGroup(gctx.mipgen.bind_group_layout, &[_]BindGroupEntryInfo{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = 8 },
            .{ .binding = 1, .texture_view_handle = texture_view },
            .{ .binding = 2, .texture_view_handle = gctx.mipgen.scratch_texture_views[0] },
            .{ .binding = 3, .texture_view_handle = gctx.mipgen.scratch_texture_views[1] },
            .{ .binding = 4, .texture_view_handle = gctx.mipgen.scratch_texture_views[2] },
            .{ .binding = 5, .texture_view_handle = gctx.mipgen.scratch_texture_views[3] },
        });
        defer gctx.destroyResource(bind_group);

        const MipgenUniforms = extern struct {
            src_mip_level: i32,
            num_mip_levels: u32,
        };
        const mem = gctx.uniformsAllocate(MipgenUniforms, 1);
        mem.slice[0] = .{
            .src_mip_level = 0,
            .num_mip_levels = 4,
        };

        const pass = encoder.beginComputePass(null);

        pass.setPipeline(gctx.lookupResource(gctx.mipgen.pipeline).?);
        pass.setBindGroup(0, gctx.lookupResource(bind_group).?, &.{mem.offset});
        pass.dispatch(1024 / 8, 1024 / 8, 1);

        pass.end();
        pass.release();

        encoder.copyTextureToTexture(
            &.{ .texture = gctx.lookupResource(gctx.mipgen.scratch_texture).?, .mip_level = 0 },
            &.{ .texture = gctx.lookupResource(texture).?, .mip_level = 1 },
            &.{ .width = 512, .height = 512 },
        );
        encoder.copyTextureToTexture(
            &.{ .texture = gctx.lookupResource(gctx.mipgen.scratch_texture).?, .mip_level = 1 },
            &.{ .texture = gctx.lookupResource(texture).?, .mip_level = 2 },
            &.{ .width = 256, .height = 256 },
        );
        encoder.copyTextureToTexture(
            &.{ .texture = gctx.lookupResource(gctx.mipgen.scratch_texture).?, .mip_level = 2 },
            &.{ .texture = gctx.lookupResource(texture).?, .mip_level = 3 },
            &.{ .width = 128, .height = 128 },
        );
        encoder.copyTextureToTexture(
            &.{ .texture = gctx.lookupResource(gctx.mipgen.scratch_texture).?, .mip_level = 3 },
            &.{ .texture = gctx.lookupResource(texture).?, .mip_level = 4 },
            &.{ .width = 64, .height = 64 },
        );
    }
};

pub const BufferHandle = struct { index: u16 align(4) = 0, generation: u16 = 0 };
pub const TextureHandle = struct { index: u16 align(4) = 0, generation: u16 = 0 };
pub const TextureViewHandle = struct { index: u16 align(4) = 0, generation: u16 = 0 };
pub const SamplerHandle = struct { index: u16 align(4) = 0, generation: u16 = 0 };
pub const RenderPipelineHandle = struct { index: u16 align(4) = 0, generation: u16 = 0 };
pub const ComputePipelineHandle = struct { index: u16 align(4) = 0, generation: u16 = 0 };
pub const BindGroupHandle = struct { index: u16 align(4) = 0, generation: u16 = 0 };
pub const BindGroupLayoutHandle = struct { index: u16 align(4) = 0, generation: u16 = 0 };
pub const PipelineLayoutHandle = struct { index: u16 align(4) = 0, generation: u16 = 0 };

pub const BufferInfo = struct {
    gpuobj: ?gpu.Buffer = null,
    size: usize = 0,
    usage: gpu.BufferUsage = .{},
};

pub const TextureInfo = struct {
    gpuobj: ?gpu.Texture = null,
    usage: gpu.Texture.Usage = .{},
    dimension: gpu.Texture.Dimension = .dimension_1d,
    size: gpu.Extent3D = .{ .width = 0 },
    format: gpu.Texture.Format = .none,
    mip_level_count: u32 = 0,
    sample_count: u32 = 0,
};

pub const TextureViewInfo = struct {
    gpuobj: ?gpu.TextureView = null,
    format: gpu.Texture.Format = .none,
    dimension: gpu.TextureView.Dimension = .dimension_none,
    base_mip_level: u32 = 0,
    mip_level_count: u32 = 0,
    base_array_layer: u32 = 0,
    array_layer_count: u32 = 0,
    aspect: gpu.Texture.Aspect = .all,
    parent_texture_handle: TextureHandle = .{},
};

pub const SamplerInfo = struct {
    gpuobj: ?gpu.Sampler = null,
    address_mode_u: gpu.AddressMode = .repeat,
    address_mode_v: gpu.AddressMode = .repeat,
    address_mode_w: gpu.AddressMode = .repeat,
    mag_filter: gpu.FilterMode = .nearest,
    min_filter: gpu.FilterMode = .nearest,
    mipmap_filter: gpu.FilterMode = .nearest,
    lod_min_clamp: f32 = 0.0,
    lod_max_clamp: f32 = 0.0,
    compare: gpu.CompareFunction = .none,
    max_anisotropy: u16 = 0,
};

pub const RenderPipelineInfo = struct {
    gpuobj: ?gpu.RenderPipeline = null,
    pipeline_layout_handle: PipelineLayoutHandle = .{},
};

pub const ComputePipelineInfo = struct {
    gpuobj: ?gpu.ComputePipeline = null,
    pipeline_layout_handle: PipelineLayoutHandle = .{},
};

pub const BindGroupEntryInfo = struct {
    binding: u32 = 0,
    buffer_handle: ?BufferHandle = null,
    offset: u64 = 0,
    size: u64 = 0,
    sampler_handle: ?SamplerHandle = null,
    texture_view_handle: ?TextureViewHandle = null,
};

const max_num_bindings_per_group = 8;

pub const BindGroupInfo = struct {
    gpuobj: ?gpu.BindGroup = null,
    num_entries: u32 = 0,
    entries: [max_num_bindings_per_group]BindGroupEntryInfo =
        [_]BindGroupEntryInfo{.{}} ** max_num_bindings_per_group,
};

pub const BindGroupLayoutInfo = struct {
    gpuobj: ?gpu.BindGroupLayout = null,
    num_entries: u32 = 0,
    entries: [max_num_bindings_per_group]gpu.BindGroupLayout.Entry =
        [_]gpu.BindGroupLayout.Entry{.{ .binding = 0, .visibility = .{} }} ** max_num_bindings_per_group,
};

const max_num_bind_groups_per_pipeline = 4;

pub const PipelineLayoutInfo = struct {
    gpuobj: ?gpu.PipelineLayout = null,
    num_bind_group_layouts: u32 = 0,
    bind_group_layouts: [max_num_bind_groups_per_pipeline]BindGroupLayoutHandle =
        [_]BindGroupLayoutHandle{.{}} ** max_num_bind_groups_per_pipeline,
};

const BufferPool = ResourcePool(BufferInfo, BufferHandle);
const TexturePool = ResourcePool(TextureInfo, TextureHandle);
const TextureViewPool = ResourcePool(TextureViewInfo, TextureViewHandle);
const SamplerPool = ResourcePool(SamplerInfo, SamplerHandle);
const RenderPipelinePool = ResourcePool(RenderPipelineInfo, RenderPipelineHandle);
const ComputePipelinePool = ResourcePool(ComputePipelineInfo, ComputePipelineHandle);
const BindGroupPool = ResourcePool(BindGroupInfo, BindGroupHandle);
const BindGroupLayoutPool = ResourcePool(BindGroupLayoutInfo, BindGroupLayoutHandle);
const PipelineLayoutPool = ResourcePool(PipelineLayoutInfo, PipelineLayoutHandle);

fn ResourcePool(comptime ResourceInfo: type, comptime ResourceHandle: type) type {
    return struct {
        const Self = @This();

        resources: []ResourceInfo,
        generations: []u16,
        start_slot_index: u32 = 0,

        fn init(allocator: std.mem.Allocator, capacity: u32) Self {
            var resources = allocator.alloc(ResourceInfo, capacity + 1) catch unreachable;
            for (resources) |*resource| resource.* = .{};

            var generations = allocator.alloc(u16, capacity + 1) catch unreachable;
            for (generations) |*gen| gen.* = 0;

            return .{
                .resources = resources,
                .generations = generations,
            };
        }

        fn deinit(pool: *Self, allocator: std.mem.Allocator) void {
            for (pool.resources) |resource| {
                if (resource.gpuobj) |gpuobj| {
                    if (@hasDecl(@TypeOf(gpuobj), "destroy")) {
                        gpuobj.destroy();
                    }
                    gpuobj.release();
                }
            }
            allocator.free(pool.resources);
            allocator.free(pool.generations);
            pool.* = undefined;
        }

        fn addResource(pool: *Self, gctx: GraphicsContext, resource: ResourceInfo) ResourceHandle {
            assert(resource.gpuobj != null);

            var index: u32 = 0;
            var found_slot_index: u32 = 0;
            while (index < pool.resources.len) : (index += 1) {
                const slot_index = (pool.start_slot_index + index) % @intCast(u32, pool.resources.len);
                if (slot_index == 0) // Skip index 0 because it is reserved for `invalid handle`.
                    continue;
                if (pool.resources[slot_index].gpuobj == null) { // If `gpuobj` is null slot is free.
                    found_slot_index = slot_index;
                    break;
                } else {
                    // If `gpuobj` is not null slot can still be free because dependent resources could
                    // have become invalid. For example, texture view becomes invalid when parent texture
                    // is destroyed.
                    const handle = ResourceHandle{ // Construct a *valid* handle for the slot that we want to check.
                        .index = @intCast(u16, slot_index),
                        .generation = pool.generations[slot_index],
                    };
                    // Check the handle (will always be valid) and its potential dependencies (may be invalid).
                    if (!gctx.isResourceValid(handle)) {
                        // Destroy old resource (it is invalid because some of its dependencies are invalid).
                        pool.destroyResource(handle);
                        found_slot_index = slot_index;
                        break;
                    }
                }
            }
            // TODO: For now we just assert if pool is full - make it more roboust.
            assert(found_slot_index > 0 and found_slot_index < pool.resources.len);

            pool.start_slot_index = found_slot_index + 1;
            pool.resources[found_slot_index] = resource;
            return .{
                .index = @intCast(u16, found_slot_index),
                .generation = generation: {
                    pool.generations[found_slot_index] += 1;
                    break :generation pool.generations[found_slot_index];
                },
            };
        }

        fn destroyResource(pool: Self, handle: ResourceHandle) void {
            if (!pool.isHandleValid(handle))
                return;
            var resource_info = &pool.resources[handle.index];

            const gpuobj = resource_info.gpuobj.?;
            if (@hasDecl(@TypeOf(gpuobj), "destroy")) {
                gpuobj.destroy();
            }
            gpuobj.release();
            resource_info.* = .{};
        }

        fn isHandleValid(pool: Self, handle: ResourceHandle) bool {
            return handle.index > 0 and
                handle.index < pool.resources.len and
                handle.generation > 0 and
                handle.generation == pool.generations[handle.index] and
                pool.resources[handle.index].gpuobj != null;
        }
    };
}

pub fn checkContent(comptime content_dir: []const u8) !void {
    const local = struct {
        fn impl() !void {
            // Change directory to where an executable is located.
            {
                var exe_path_buffer: [1024]u8 = undefined;
                const exe_path = std.fs.selfExeDirPath(exe_path_buffer[0..]) catch "./";
                std.os.chdir(exe_path) catch {};
            }
            // Make sure font file is a valid data file and not just a Git LFS pointer.
            {
                const file = try std.fs.cwd().openFile(content_dir ++ "Roboto-Medium.ttf", .{});
                defer file.close();

                const size = @intCast(usize, try file.getEndPos());
                if (size <= 1024) {
                    return error.InvalidDataFiles;
                }
            }
        }
    };
    local.impl() catch |err| {
        std.debug.print(
            \\
            \\DATA ERROR
            \\
            \\Invalid data files or missing content folder.
            \\Please install Git LFS (Large File Support) and run (in the repo):
            \\
            \\git lfs install
            \\git pull
            \\
            \\For more info please see: https://git-lfs.github.com/
            \\
            \\
        ,
            .{},
        );
        return err;
    };
}

const FrameStats = struct {
    time: f64 = 0.0,
    delta_time: f32 = 0.0,
    fps_counter: u32 = 0,
    fps: f64 = 0.0,
    average_cpu_time: f64 = 0.0,
    previous_time: f64 = 0.0,
    fps_refresh_time: f64 = 0.0,
    cpu_frame_number: u64 = 0,
    gpu_frame_number: u64 = 0,

    fn tick(stats: *FrameStats) void {
        stats.time = glfw.getTime();
        stats.delta_time = @floatCast(f32, stats.time - stats.previous_time);
        stats.previous_time = stats.time;

        if ((stats.time - stats.fps_refresh_time) >= 1.0) {
            const t = stats.time - stats.fps_refresh_time;
            const fps = @intToFloat(f64, stats.fps_counter) / t;
            const ms = (1.0 / fps) * 1000.0;

            stats.fps = fps;
            stats.average_cpu_time = ms;
            stats.fps_refresh_time = stats.time;
            stats.fps_counter = 0;
        }
        stats.fps_counter += 1;
        stats.cpu_frame_number += 1;
    }
};

pub const gui = struct {
    pub fn init(
        window: glfw.Window,
        device: gpu.Device,
        comptime content_dir: []const u8,
        comptime font_name: [*:0]const u8,
        font_size: f32,
    ) void {
        assert(cimgui.igGetCurrentContext() == null);
        _ = cimgui.igCreateContext(null);

        if (!ImGui_ImplGlfw_InitForOther(window.handle, true)) {
            unreachable;
        }

        const io = cimgui.igGetIO().?;
        if (cimgui.ImFontAtlas_AddFontFromFileTTF(
            io.*.Fonts,
            content_dir ++ font_name,
            font_size,
            null,
            null,
        ) == null) {
            unreachable;
        }

        if (!ImGui_ImplWGPU_Init(
            device.ptr,
            1, // Number of `frames in flight`. One is enough because Dawn creates staging buffers internally.
            @enumToInt(GraphicsContext.swapchain_format),
        )) {
            unreachable;
        }

        io.*.IniFilename = content_dir ++ "imgui.ini";
    }

    pub fn deinit() void {
        assert(cimgui.igGetCurrentContext() != null);
        ImGui_ImplWGPU_Shutdown();
        ImGui_ImplGlfw_Shutdown();
        cimgui.igDestroyContext(null);
    }

    pub fn newFrame(fb_width: u32, fb_height: u32) void {
        ImGui_ImplWGPU_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        {
            const io = cimgui.igGetIO().?;
            io.*.DisplaySize = .{
                .x = @intToFloat(f32, fb_width),
                .y = @intToFloat(f32, fb_height),
            };
            io.*.DisplayFramebufferScale = .{ .x = 1.0, .y = 1.0 };
        }
        cimgui.igNewFrame();
    }

    pub fn draw(pass: gpu.RenderPassEncoder) void {
        cimgui.igRender();
        ImGui_ImplWGPU_RenderDrawData(cimgui.igGetDrawData(), pass.ptr);
    }

    extern fn ImGui_ImplGlfw_InitForOther(window: *anyopaque, install_callbacks: bool) bool;
    extern fn ImGui_ImplGlfw_NewFrame() void;
    extern fn ImGui_ImplGlfw_Shutdown() void;
    extern fn ImGui_ImplWGPU_Init(device: *anyopaque, num_frames_in_flight: u32, rt_format: u32) bool;
    extern fn ImGui_ImplWGPU_NewFrame() void;
    extern fn ImGui_ImplWGPU_RenderDrawData(draw_data: *anyopaque, pass_encoder: *anyopaque) void;
    extern fn ImGui_ImplWGPU_Shutdown() void;
};

pub const stbi = struct {
    pub const Image = struct {
        data: []u8,
        width: u32,
        height: u32,
        channels_in_memory: u32,
        channels_in_file: u32,

        pub fn init(
            filename: [*:0]const u8,
            desired_channels: u32,
        ) !Image {
            var x: c_int = undefined;
            var y: c_int = undefined;
            var ch: c_int = undefined;
            const data = stbi_load(filename, &x, &y, &ch, @intCast(c_int, desired_channels));
            if (data == null)
                return error.stbi_LoadFailed;

            const channels_in_memory = if (desired_channels == 0) @intCast(u32, ch) else desired_channels;
            const width = @intCast(u32, x);
            const height = @intCast(u32, y);
            return Image{
                .data = data.?[0 .. width * height * channels_in_memory],
                .width = width,
                .height = height,
                .channels_in_memory = channels_in_memory,
                .channels_in_file = @intCast(u32, ch),
            };
        }

        pub fn deinit(image: *Image) void {
            stbi_image_free(image.data.ptr);
            image.* = undefined;
        }
    };

    extern fn stbi_load(
        filename: [*:0]const u8,
        x: *c_int,
        y: *c_int,
        channels_in_file: *c_int,
        desired_channels: c_int,
    ) ?[*]u8;
    extern fn stbi_image_free(image_data: ?*anyopaque) void;
};

fn detectGLFWOptions() glfw.BackendOptions {
    const target = @import("builtin").target;
    if (target.isDarwin()) return .{ .cocoa = true };
    return switch (target.os.tag) {
        .windows => .{ .win32 = true },
        .linux => .{ .x11 = true },
        else => .{},
    };
}

fn createSurfaceForWindow(
    native_instance: *const gpu.NativeInstance,
    window: glfw.Window,
    comptime glfw_options: glfw.BackendOptions,
) gpu.Surface {
    const glfw_native = glfw.Native(glfw_options);
    const descriptor = if (glfw_options.win32) gpu.Surface.Descriptor{
        .windows_hwnd = .{
            .label = "basic surface",
            .hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?,
            .hwnd = glfw_native.getWin32Window(window),
        },
    } else if (glfw_options.x11) gpu.Surface.Descriptor{
        .xlib = .{
            .label = "basic surface",
            .display = glfw_native.getX11Display(),
            .window = glfw_native.getX11Window(window),
        },
    } else if (glfw_options.cocoa) blk: {
        const ns_window = glfw_native.getCocoaWindow(window);
        const ns_view = msgSend(ns_window, "contentView", .{}, *anyopaque); // [nsWindow contentView]

        // Create a CAMetalLayer that covers the whole window that will be passed to CreateSurface.
        msgSend(ns_view, "setWantsLayer:", .{true}, void); // [view setWantsLayer:YES]
        const layer = msgSend(objc.objc_getClass("CAMetalLayer"), "layer", .{}, ?*anyopaque); // [CAMetalLayer layer]
        if (layer == null) @panic("failed to create Metal layer");
        msgSend(ns_view, "setLayer:", .{layer.?}, void); // [view setLayer:layer]

        // Use retina if the window was created with retina support.
        const scale_factor = msgSend(ns_window, "backingScaleFactor", .{}, f64); // [ns_window backingScaleFactor]
        msgSend(layer.?, "setContentsScale:", .{scale_factor}, void); // [layer setContentsScale:scale_factor]

        break :blk gpu.Surface.Descriptor{
            .metal_layer = .{
                .label = "basic surface",
                .layer = layer.?,
            },
        };
    } else if (glfw_options.wayland) {
        // bugs.chromium.org/p/dawn/issues/detail?id=1246&q=surface&can=2
        @panic("Dawn does not yet have Wayland support");
    } else unreachable;

    return native_instance.createSurface(&descriptor);
}

// Borrowed from https://github.com/hazeycode/zig-objcrt
fn msgSend(obj: anytype, sel_name: [:0]const u8, args: anytype, comptime ReturnType: type) ReturnType {
    const args_meta = @typeInfo(@TypeOf(args)).Struct.fields;

    const FnType = switch (args_meta.len) {
        0 => fn (@TypeOf(obj), objc.SEL) callconv(.C) ReturnType,
        1 => fn (@TypeOf(obj), objc.SEL, args_meta[0].field_type) callconv(.C) ReturnType,
        2 => fn (@TypeOf(obj), objc.SEL, args_meta[0].field_type, args_meta[1].field_type) callconv(.C) ReturnType,
        3 => fn (
            @TypeOf(obj),
            objc.SEL,
            args_meta[0].field_type,
            args_meta[1].field_type,
            args_meta[2].field_type,
        ) callconv(.C) ReturnType,
        4 => fn (
            @TypeOf(obj),
            objc.SEL,
            args_meta[0].field_type,
            args_meta[1].field_type,
            args_meta[2].field_type,
            args_meta[3].field_type,
        ) callconv(.C) ReturnType,
        else => @compileError("[zgpu] Unsupported number of args"),
    };

    // NOTE: `func` is a var because making it const causes a compile error which I believe is a compiler bug.
    var func = @ptrCast(FnType, objc.objc_msgSend);
    const sel = objc.sel_getUid(sel_name);

    return @call(.{}, func, .{ obj, sel } ++ args);
}

fn printUnhandledError(_: void, typ: gpu.ErrorType, message: [*:0]const u8) void {
    switch (typ) {
        .validation => std.debug.print("[zgpu] Validation error: {s}\n", .{message}),
        .out_of_memory => std.debug.print("[zgpu] Out of memory: {s}\n", .{message}),
        .device_lost => std.debug.print("[zgpu] Device lost: {s}\n", .{message}),
        .unknown => std.debug.print("[zgpu] Unknown error: {s}\n", .{message}),
        else => unreachable,
    }
    // TODO: Do something better.
    std.process.exit(1);
}
var printUnhandledErrorCallback = gpu.ErrorCallback.init(void, {}, printUnhandledError);

fn handleToGpuResourceType(comptime T: type) type {
    return switch (T) {
        BufferHandle => gpu.Buffer,
        TextureHandle => gpu.Texture,
        TextureViewHandle => gpu.TextureView,
        SamplerHandle => gpu.Sampler,
        RenderPipelineHandle => gpu.RenderPipeline,
        ComputePipelineHandle => gpu.ComputePipeline,
        BindGroupHandle => gpu.BindGroup,
        BindGroupLayoutHandle => gpu.BindGroupLayout,
        PipelineLayoutHandle => gpu.PipelineLayout,
        else => @compileError("[zgpu] handleToGpuResourceType() not implemented for " ++ @typeName(T)),
    };
}

fn handleToResourceInfoType(comptime T: type) type {
    return switch (T) {
        BufferHandle => BufferInfo,
        TextureHandle => TextureInfo,
        TextureViewHandle => TextureViewInfo,
        SamplerHandle => SamplerInfo,
        RenderPipelineHandle => RenderPipelineInfo,
        ComputePipelineHandle => ComputePipelineInfo,
        BindGroupHandle => BindGroupInfo,
        BindGroupLayoutHandle => BindGroupLayoutInfo,
        PipelineLayoutHandle => PipelineLayoutInfo,
        else => @compileError("[zgpu] handleToResourceInfoType() not implemented for " ++ @typeName(T)),
    };
}

pub const bglBuffer = gpu.BindGroupLayout.Entry.buffer;
pub const bglTexture = gpu.BindGroupLayout.Entry.texture;
pub const bglSampler = gpu.BindGroupLayout.Entry.sampler;
pub const bglStorageTexture = gpu.BindGroupLayout.Entry.storageTexture;
