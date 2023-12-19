#version 460

layout (local_size_x = 8, local_size_y = 8) in;

layout (rgba8, binding = 0) uniform writeonly image2D outImage;

uniform uvec2 screenSize;
uniform uvec3 terrainSize;
uniform uint treeDepth;
uniform vec3 camPos;
uniform mat4 viewMat;
uniform mat4 projMat;

#define NODE_WIDTH 2
#define MAX_DDA_STEPS 128
#define MINI_STEP_SIZE 4e-2
#define NODE_SIZE NODE_WIDTH * NODE_WIDTH * NODE_WIDTH

layout (std430, binding = 0) readonly buffer node_pool
{
    uint nodePool[];
};

layout (std430, binding = 1) readonly buffer chunk_pool
{
    uint chunkPool[];
};

// voxel palette. it mirrors materials.h
vec3 colors[] = {
vec3(1.00, 0.40, 0.40), // UNDEFINED
vec3(0.69, 0.88, 0.90), // AIR
vec3(0.33, 0.33, 0.33), // STONE
vec3(0.42, 0.32, 0.25), // DIRT
vec3(0.30, 0.39, 0.31)  // GRASS
};
vec3 debug_colors[] = {
vec3(1.0, 0.5, 0.5),
vec3(0.8, 0.25, 0.25),
vec3(0.5, 1., 0.5),
vec3(0., 0.8, 0.),
vec3(0.25, 0.8, 0.25),
vec3(0.5, 0.5, 1.),
vec3(0., 0., 0.8),
vec3(0.25, 0.25, 0.8),
};

vec3 getRayDir(ivec2 screenPos)
{
    vec2 screenSpace = (screenPos + vec2(0.5)) / vec2(screenSize);
    vec4 clipSpace = vec4(screenSpace * 2.0f - 1.0f, -1.0, 1.0);
    vec4 eyeSpace = vec4(vec2(inverse(projMat) * clipSpace), -1.0, 0.0);
    return normalize(vec3(inverse(viewMat) * eyeSpace));
}

float AABBIntersect(vec3 bmin, vec3 bmax, vec3 orig, vec3 invdir)
{
    vec3 t0 = (bmin - orig) * invdir;
    vec3 t1 = (bmax - orig) * invdir;

    vec3 vmin = min(t0, t1);
    vec3 vmax = max(t0, t1);

    float tmin = max(vmin.x, max(vmin.y, vmin.z));
    float tmax = min(vmax.x, min(vmax.y, vmax.z));

    if (!(tmax < tmin) && (tmax >= 0))
    return max(0, tmin);
    return -1;
}

float sign11(float x)
{
    return x<0. ? -1. : 1.;
}

void main()
{
    // make sure current thread is inside the window bounds
    if (any(greaterThanEqual(gl_GlobalInvocationID.xy, screenSize)))
    return;

    // calc ray direction for current pixel
    vec3 rayDir = getRayDir(ivec2(gl_GlobalInvocationID.xy));
    vec3 previousRayPos, rayPos = camPos;

    // check if the camera is outside the voxel volume
    float intersect = AABBIntersect(vec3(0), vec3(terrainSize - 1), camPos, 1.0f / rayDir);

    // if it is outside the terrain, offset the ray so its starting position is (slightly) in the voxel volume
    if (intersect > 0) {
        rayPos += rayDir * (intersect + 0.001);
    }

    // if the ray intersect the terrain, raytrace
    vec3 color = vec3(0.69, 0.88, 0.90); // this is the sky color

    if (intersect >= 0) {
        uint depth = 0;

        // at any time, node_width = terrain_width / NODE_WIDTH**depth
        uint node_width = terrainSize.x;

        // at any time, the top-most stack address is stack[depth]
        uint stack[12];

        // index of the current node in the pool
        uint current_node = 0;
        uint previous_node = 0;

        // color code of the last valid node
        uint color_code;

        // Compute once and for all a few variables
        vec3 invertedRayDir = 1. / rayDir;
        vec3 raySign = vec3(sign11(rayDir.x), sign11(rayDir.y), sign11(rayDir.z));
        vec3 raySign01 = max(raySign, 0.);

        for(int i=0; i<MAX_DDA_STEPS; i++) {
            // setting the stack to the starting pos of the ray
            do {
                stack[depth] = current_node;
                depth += 1;
                node_width /= NODE_WIDTH;
                uvec3 r = uvec3(mod(rayPos, node_width * NODE_WIDTH) / node_width);
                uint node_data = nodePool[current_node * NODE_SIZE + r.x + r.z * NODE_WIDTH + r.y * NODE_WIDTH * NODE_WIDTH];
                previous_node = current_node;
                current_node = (node_data & 0x00ffffffu);
                color_code = (node_data >> 24);
            } while (current_node != 0 && depth < treeDepth);

            // quick exit #1: ray hit
            if (color_code != 1) break;

            // Compute step
            vec3 tMax = invertedRayDir * (node_width * raySign01 - mod(rayPos, node_width));
            float rayStep = min(tMax.x, min(tMax.y, tMax.z));

            // Compute new rayPos
            previousRayPos = rayPos;
            rayPos += rayStep*rayDir;
            rayPos += MINI_STEP_SIZE*raySign; // TODO: improve this

        /*
            ivec3 mapPos = ivec3(floor(rayPos/node_width));
            vec3 sideDist = (sign(rayDir) * (vec3(mapPos) - rayPos/node_width) + (sign(rayDir) * 0.5) + 0.5) * deltaDist;
            bvec3 mask = lessThanEqual(sideDist.xyz, min(sideDist.yzx, sideDist.zxy));
            sideDist += vec3(mask) * deltaDist;
            mapPos += ivec3(vec3(mask)) * rayStep;
            previousRayPos = rayPos;
            rayPos += rayDir;*/

            // Quick exit #2: ray exiting the volume
            if (any(greaterThanEqual(rayPos, terrainSize)) || any(lessThan(rayPos, vec3(0)))) break;

            // While pos+step is not in current_node, step up
            do {
                node_width *= NODE_WIDTH;
                depth -= 1;
                current_node = stack[depth];
            } while (depth > 0 && any(lessThan(rayPos, previousRayPos - mod(previousRayPos, node_width))) || any(greaterThanEqual(rayPos, previousRayPos + node_width - mod(previousRayPos, node_width))));
        }

        // TODO finish the above code
        // TODO support chunk leafs (I'm scared)

        // ensuring the color code is valid
        if (color_code >= colors.length()) {
            color.xyz = colors[0].xyz;
        } else if (color_code > 1) {
            // using per-node color to debug the octree
            // the whole "else-if" block can be commented to restore the original colors
            color.xyz = debug_colors[previous_node % debug_colors.length()].xyz;
        } else {
            // setting the pixel color using the color table
            color.xyz = colors[color_code].xyz;
        }
    }

    // output color to texture
    imageStore(outImage, ivec2(gl_GlobalInvocationID.xy), vec4(color, 1));
}
