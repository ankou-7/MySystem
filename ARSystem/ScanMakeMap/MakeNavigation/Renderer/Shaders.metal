//
//  Shaders.metal
//  ARMeshNavigation
//
//  Created by 安江洸希 on 2021/03/04.
//

#include <metal_stdlib>
#include <simd/simd.h>

#import "ShaderTypes.h"

using namespace metal;

//#include <SceneKit/scn_metal>

constexpr sampler colorSampler(mip_filter::linear, mag_filter::linear, min_filter::linear);
constant auto yCbCrToRGB = float4x4(float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
                                    float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
                                    float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
                                    float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));
constant float2 viewVertices[] = { float2(-1, 1), float2(-1, -1), float2(1, 1), float2(1, -1) };
constant float2 viewTexCoords[] = { float2(0, 0), float2(0, 1), float2(1, 0), float2(1, 1) };

/// Retrieves the world position of a specified camera point with depth
static simd_float4 worldPoint(simd_float2 cameraPoint, float depth, matrix_float3x3 cameraIntrinsicsInversed, matrix_float4x4 localToWorld) {
    const auto localPoint = cameraIntrinsicsInversed * simd_float3(cameraPoint, 1) * depth;
    const auto worldPoint = localToWorld * simd_float4(localPoint, 1);
    
    return worldPoint / worldPoint.w;
}

//画面上の２次元点情報を３次元点情報に置き換える
///  Vertex shader that takes in a 2D grid-point and infers its 3D position in world-space, along with RGB and confidence
vertex void unprojectVertex(uint vertexID [[vertex_id]],
                            constant PointCloudUniforms &uniforms [[buffer(kPointCloudUniforms)]],
                            device ParticleUniforms *particleUniforms [[buffer(kParticleUniforms)]],
                            constant float2 *gridPoints [[buffer(kGridPoints)]],
                            texture2d<float, access::sample> capturedImageTextureY [[texture(kTextureY)]],
                            texture2d<float, access::sample> capturedImageTextureCbCr [[texture(kTextureCbCr)]],
                            texture2d<float, access::sample> depthTexture [[texture(kTextureDepth)]],
                            texture2d<unsigned int, access::sample> confidenceTexture [[texture(kTextureConfidence)]]) {
    
    const auto gridPoint = gridPoints[vertexID];
    //超えないようにしている
    const auto currentPointIndex = (uniforms.pointCloudCurrentIndex + vertexID) % uniforms.maxPoints;
    const auto texCoord = gridPoint / uniforms.cameraResolution;
    // Sample the depth map to get the depth value
    const auto depth = depthTexture.sample(colorSampler, texCoord).r;
    //const auto depth = 1.0 - depthTexture.sample(colorSampler, texCoord).r;
    // With a 2D point plus depth, we can now get its 3D position
    const auto position = worldPoint(gridPoint, depth, uniforms.cameraIntrinsicsInversed, uniforms.localToWorld);
    
    // Sample Y and CbCr textures to get the YCbCr color at the given texture coordinate
    const auto ycbcr = float4(capturedImageTextureY.sample(colorSampler, texCoord).r, capturedImageTextureCbCr.sample(colorSampler, texCoord.xy).rg, 1);
    const auto sampledColor = (yCbCrToRGB * ycbcr).rgb;
    // Sample the confidence map to get the confidence value
    const auto confidence = confidenceTexture.sample(colorSampler, texCoord).r;
    
    // Write the data to the buffer
    particleUniforms[currentPointIndex].position = position.xyz;
    particleUniforms[currentPointIndex].color = sampledColor;
    particleUniforms[currentPointIndex].confidence = confidence;
}

//depth計算
vertex void depth(uint id [[vertex_id]],
                  constant PointCloudUniforms &uniforms [[buffer(kPointCloudUniforms)]],
                  device DepthUniforms *depthUniforms [[buffer(kParticleUniforms)]],
                  constant float2 *gridPoints [[buffer(kGridPoints)]],
                  texture2d<float, access::sample> depthTexture [[texture(kTextureDepth)]],
                  texture2d<unsigned int, access::sample> confidenceTexture [[texture(kTextureConfidence)]]) {
    
    const auto gridPoint = gridPoints[id];
    const auto currentPointIndex = (uniforms.pointCloudCurrentIndex + id) % uniforms.maxPoints;
    const auto texCoord = gridPoint / uniforms.cameraResolution;
    const auto depth = depthTexture.sample(colorSampler, texCoord).r;
    const auto position = worldPoint(gridPoint, depth, uniforms.cameraIntrinsicsInversed, uniforms.localToWorld);
    float4 projectedPosition = position;//uniforms.viewProjectionMatrix *
    projectedPosition /= projectedPosition.w;
    
    const auto confidence = confidenceTexture.sample(colorSampler, texCoord).r;
    
    depthUniforms[currentPointIndex].position = projectedPosition.xyz;
    depthUniforms[currentPointIndex].confidence = confidence;
}


// Camera's RGB vertex shader outputs
struct RGBVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

//カメラから取得した画像情報用
vertex RGBVertexOut rgbVertex(uint vertexID [[vertex_id]],
                              constant RGBUniforms &uniforms [[buffer(0)]]) {
    const float3 texCoord = float3(viewTexCoords[vertexID], 1) * uniforms.viewToCamera;

    RGBVertexOut out;
    out.position = float4(viewVertices[vertexID], 0, 1);
    out.texCoord = texCoord.xy;

    return out;
}

fragment float4 rgbFragment(RGBVertexOut in [[stage_in]],
                            constant RGBUniforms &uniforms [[buffer(0)]],
                            texture2d<float, access::sample> capturedImageTextureY [[texture(kTextureY)]],
                            texture2d<float, access::sample> capturedImageTextureCbCr [[texture(kTextureCbCr)]]) {

    const float2 offset = (in.texCoord - 0.5) * float2(1, 1 / uniforms.viewRatio) * 2;
    const float visibility = saturate(uniforms.radius * uniforms.radius - length_squared(offset));
    const float4 ycbcr = float4(capturedImageTextureY.sample(colorSampler, in.texCoord.xy).r, capturedImageTextureCbCr.sample(colorSampler, in.texCoord.xy).rg, 1);

    // convert and save the color back to the buffer
    const float3 sampledColor = (yCbCrToRGB * ycbcr).rgb;
    return float4(sampledColor, 1) * visibility;
}


// Particle vertex shader outputs and fragment shader inputs
struct ParticleVertexOut {
    float4 position [[position]]; //特徴点の３次元座標
    float pointSize [[point_size]]; //特徴点の大きさ
    float4 color; //特徴点の色情報
};
struct ParticleFragmentOut {
    float depth [[depth(any)]]; //深度情報
    float4 color; //色情報
};

//取得した特徴点用
vertex ParticleVertexOut particleVertex(uint vertexID [[vertex_id]],
                                        constant PointCloudUniforms &uniforms [[buffer(kPointCloudUniforms)]],
                                        constant ParticleUniforms *particleUniforms [[buffer(kParticleUniforms)]]) {
    
    // get point data
    const auto particleData = particleUniforms[vertexID];
    const auto position = particleData.position;
    const auto confidence = particleData.confidence;
    const auto sampledColor = particleData.color;
    const auto visibility = confidence >= uniforms.confidenceThreshold;
    
    // animate and project the point
    float4 projectedPosition = uniforms.viewProjectionMatrix * float4(position, 1.0);

    //const float pointSize = max(uniforms.particleSize / max(1.0, projectedPosition.z), 2.0);
    //const float pointSize = 20.0; // ADDED
    const float pointSize = uniforms.particleSize;
  
    projectedPosition /= projectedPosition.w;
    
    // prepare for output
    ParticleVertexOut out;
    out.position = projectedPosition;
    out.pointSize = 5.0f; //pointSize;
    out.color = float4(sampledColor, visibility);
    
    return out;
}

fragment ParticleFragmentOut particleFragment(ParticleVertexOut in [[stage_in]],
                                 const float2 coords [[point_coord]]) {
    // we draw within a circle
    //特徴点の形を四角形から円形にしている
    const float distSquared = length_squared(coords - float2(0.5));
    if (in.color.a == 0 || distSquared > 0.25) {
        discard_fragment(); //当該のピクセルを放棄
    }

    ParticleFragmentOut out;

    // scale depth values to a range compatible
    // with depth buffer rendered by SceneKit
    out.depth = 1.0 - in.position.z;
    out.color = in.color;

    return out;
}

///////////
vertex ParticleVertexOut particleVertex2(uint vertexID [[vertex_id]],
                                         constant ParticleUniforms *particleUniforms [[buffer(kParticleUniforms)]]) {
    
    const auto particleData = particleUniforms[vertexID];
    const auto position = particleData.position;
    const auto sampledColor = particleData.color;
    
    // prepare for output
    ParticleVertexOut out;
    out.position = float4(position,1.0);
    out.pointSize = 5.0f;
    out.color = float4(sampledColor, 1.0);
    
    return out;
}

fragment float4 particleFragment2(ParticleVertexOut in [[stage_in]],
                                               const float2 coords [[point_coord]]) {
    //特徴点の形を四角形から円形にしている
    const float distSquared = length_squared(coords - float2(0.5));
    if (in.color.a == 0 || distSquared > 0.25) {
        discard_fragment(); //当該のピクセルを放棄
    }
    
//    ParticleFragmentOut out;
//
//    // scale depth values to a range compatible
//    // with depth buffer rendered by SceneKit
//    out.depth = 1.0 - in.position.z;
//    out.color = in.color;
//
//    return out;
    return in.color;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//load用
struct Vertex {
    float4 position [[position]];
    float pointSize[[point_size]];
    float4 color;
};

vertex Vertex vertex_func(constant PointCloudUniforms &uniforms [[buffer(kPointCloudUniforms)]],
                          constant float4 *positions [[buffer(1)]],
                          constant float4 *colors [[buffer(2)]],
                          uint vid [[vertex_id]]) {

    float4 projectedPosition = uniforms.viewProjectionMatrix * uniforms.rotate * positions[vid];
    //float4 projectedPosition = positions[vid];
    
    //const auto currentPointIndex = (uniforms.pointCloudCurrentIndex + vid) % uniforms.maxPoints;

    projectedPosition /= projectedPosition.w;
    //projectedPosition.y = projectedPosition.y - 0.3;
    //projectedPosition.z = projectedPosition.z + move_y;
    
    //上下左右の移動制御
    const auto pan_move = uniforms.pan_move;
    projectedPosition.x = projectedPosition.x + pan_move.x;
    projectedPosition.y = projectedPosition.y - pan_move.y;
    
    //projectedPosition.x = projectedPosition.x * uniforms.scale;
    //projectedPosition.y = projectedPosition.y * uniforms.scale;
    //projectedPosition.z = projectedPosition.z * uniforms.scale;
    
//    positions[currentPointIndex].x = projectedPosition.x;
//    positions[currentPointIndex].y = projectedPosition.y;

    //return vertices[vid];
    Vertex out;
    out.position = projectedPosition;
    out.pointSize = uniforms.particleSize; //10.0;
    out.color = colors[vid];
    return out;
}

//vertex Vertex vertex_func(constant float4 *positions [[buffer(1)]],
//                          constant float4 *colors [[buffer(2)]],
//                          uint vid [[vertex_id]]) {
//
//    //return vertices[vid];
//    Vertex out;
//    out.position = positions[vid];
//    out.pointSize = 10.0;
//    out.color = colors[vid];
//    return out;
//}

//fragment float4 fragment_func(Vertex vert [[stage_in]]) {
//    //float4 color = float4(vert.color.x, vert.color.y, vert.color.z, 1);
//
////    float3 inColor = float3(vert.color.x, vert.color.y, vert.color.z);
////    half gray = dot(kRec709Luma, inColor);
////    float4 outColor = float4(gray, gray, gray, 1);
////    return outColor;
//    return vert.color;
//    //return float4(1,0,0,1);
//}

fragment ParticleFragmentOut fragment_func(Vertex vert [[stage_in]], const float2 coords [[point_coord]]) {
    // we draw within a circle
    //特徴点の形を四角形から円形にしている
    const float distSquared = length_squared(coords - float2(0.5));
    if (vert.color.a == 0 || distSquared > 0.25) {
        discard_fragment(); //当該のピクセルを放棄
    }

    ParticleFragmentOut out;

    // scale depth values to a range compatible
    // with depth buffer rendered by SceneKit
    //out.depth = 1.0 - vert.position.z;
    out.depth = 1.5 + vert.position.z;
    out.color = vert.color;

    return out;
}


/////////////////////////////////////////////////////////////
//
struct Vertex2 {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

struct RenderParams {
    float4x4 projectionMatrix;
    float3 eyePosition;
};

vertex Vertex2 vertex_func2(//const device RenderParams &params [[buffer(0)]],
                            constant float4 *positions [[buffer(1)]],
                            constant float4 *colors [[buffer(2)]],
                            uint vid [[vertex_id]]) {
    
    Vertex2 out;
    //return vertices[vid];
    //const auto VertexData = vertices[vid];
    const auto position = positions[vid];
    //out.position = params.projectionMatrix * position;
    
    const auto color = colors[vid];

    out.position = position;
    out.pointSize = 10.0;
    out.color = color;
    return out;
}

fragment float4 fragment_func2(Vertex2 in [[stage_in]],
                               const float2 coords [[point_coord]]) {
    
    const float distSquared = length_squared(coords - float2(0.5));
    if (in.color.a == 0 || distSquared > 0.25) {
        discard_fragment(); //当該のピクセルを放棄
    }
    
    return in.color;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
kernel void calcu(const device float *inputData [[ buffer(0) ]],
                         device float *outputData [[ buffer(1) ]],
                         uint id [[ thread_position_in_grid ]])
{
    float result = inputData[id];
    result += 1.0f;
    outputData[id] = result;
}


static simd_float4 clipPoint(simd_float3 vertexPoint, matrix_float4x4 matrix) {
    const auto clipSpacePosition = matrix * simd_float4(vertexPoint, 1.0);
    
    return clipSpacePosition / clipSpacePosition.w;
}

kernel void calcu3(constant float3 *vertices [[ buffer(0) ]],
                   constant float3 *normals [[ buffer(1) ]],
                   constant int *faces [[ buffer(2) ]],
                   device float2 *texcoords [[buffer(3)]],
                   device float3 *new_vertices [[ buffer(4) ]],
                   device float3 *new_normals [[ buffer(5) ]],
                   device int *new_faces [[ buffer(6)]],
                   //device MeshUniforms *meshUniforms [[ buffer(7)]],
                   constant float4x4 &uniforms [[ buffer(8) ]],
                   constant anchorUniforms *anchorUnifoms [[ buffer(9) ]],
                   device float4 *trys [[ buffer(10) ]],
                   uint id [[ thread_position_in_grid ]])
{
    if (int(id) > anchorUnifoms[0].maxCount) {
        return;
    }
    //float3 v = vertices[id].xyz;
    new_faces[id] = int(id);
    new_vertices[id] = vertices[faces[int(id)]];
    new_normals[id] = normals[faces[int(id)]];
    
    float yoko = anchorUnifoms[0].yoko;
    float tate = anchorUnifoms[0].tate;
    
    for (int i = 0; i < anchorUnifoms[0].calcuCount; i++) {
        //const auto clipSpacePosition = uniforms[i] * float4(new_vertices[id], 1.0);
        const auto normalizedDeviceCoordinate = clipPoint(new_vertices[id], matrix_float4x4(uniforms[i*4],uniforms[i*4+1],uniforms[i*4+2], uniforms[i*4+3]));; //clipSpacePosition / clipSpacePosition.w;
        const auto pt = float3((normalizedDeviceCoordinate.x + 1) * (834 / 2),
                                    (-normalizedDeviceCoordinate.y + 1) * (1150 / 2),
                                    (1 - (-normalizedDeviceCoordinate.z + 1)));
        trys[id] = float4(pt, 1.0);
        if (pt.x >= 0 && pt.x <= 834 && pt.y >= 0 && pt.y <= 1150 && pt.z < 1.0) {
            const auto u = ((pt.x / (834 * yoko))  + (fmod(i,yoko) / yoko));
            const auto v = ((pt.y / (1150 * tate)) + (floor(i / yoko) / tate));
            texcoords[id] = float2(u, v);
        }
    }
    
    //const auto vertexPoint4 = uniforms.transform * simd_float4(vertices[faces[int(id)]],1);
    //new_vertices[id] = vertexPoint4.xyz;
    
    //meshUniforms[id].vertexs = vertices[faces[int(id)]];
    //meshUniforms[id].normals = normals[faces[int(id)]];
}

static simd_float3 mul(simd_float3 vertexPoint, matrix_float4x4 matrix) {
    const auto worldPoint4 = matrix * simd_float4(vertexPoint.x, vertexPoint.y, vertexPoint.z, 1.0);
    
    return simd_float3(worldPoint4.x, worldPoint4.y, worldPoint4.z);
}

kernel void calcu4(constant float3 *vertices [[ buffer(0) ]],
                   constant float3 *normals [[ buffer(1) ]],
                   constant int *faces [[ buffer(2) ]],
                   device float2 *texcoords [[buffer(3)]],
                   device float3 *new_vertices [[ buffer(4) ]],
                   device float3 *new_normals [[ buffer(5) ]],
                   device int *new_faces [[ buffer(6)]],
                   //device MeshUniforms *meshUniforms [[ buffer(7)]],
                   constant float4x4 &uniforms [[ buffer(8) ]],
                   constant anchorUniforms &anchorUnifoms [[ buffer(9) ]],
                   device int *trys [[ buffer(10) ]],
                   device int *faceBool [[ buffer(11) ]],
                   device float2 *facecoord [[ buffer(12) ]],
                   constant int4 *vvv [[ buffer(13) ]],
                   uint id [[ thread_position_in_grid ]])
{
    if (int(id) > anchorUnifoms.maxCount) {
        return;
    }
    
    float yoko = anchorUnifoms.yoko;
    float tate = anchorUnifoms.tate;
    
    //const auto point3 = mul(float3(vvv[1].z, vvv[1].x, vvv[1].y), anchorUnifoms.transform);
    //trys[id] = point3;
    
//    trys[0] = int3(vvv[0].x, vvv[0].y, vvv[0].w);
//    trys[1] = int3(vvv[1].x, vvv[1].y, vvv[1].z);
//    trys[2] = int3(vvv[2].x, vvv[2].y, vvv[2].z);
    if (4*id < anchorUnifoms.maxCount) {
        int n = 249;
        trys[0] = vvv[n].x;
        trys[1] = vvv[n].y;
        trys[2] = vvv[n].z;
        trys[3] = vvv[n].w;
    }
    
    for (int i = 0; i < anchorUnifoms.calcuCount; i++) {
        int count = 0;
        
        for (int j = 0; j < 3; j++) {
            new_faces[id*3 + j] = int(id*3 + j);
            new_vertices[id*3 + j] = vertices[faces[int(id*3 + j)]];
            new_normals[id*3 + j] = normals[faces[int(id*3 + j)]];
            
            const auto normalizedDeviceCoordinate = clipPoint(new_vertices[id*3 + j], matrix_float4x4(uniforms[i*4],uniforms[i*4+1],uniforms[i*4+2], uniforms[i*4+3]));
            const auto pt = float3((normalizedDeviceCoordinate.x + 1) * (834 / 2),
                                        (-normalizedDeviceCoordinate.y + 1) * (1150 / 2),
                                        (1 - (-normalizedDeviceCoordinate.z + 1)));
            if (pt.x >= 0 && pt.x <= 834 && pt.y >= 0 && pt.y <= 1150 && pt.z < 1.0) {
                count += 1;
                const auto u = ((pt.x / (834 * yoko))  + (fmod(i,yoko) / yoko));
                const auto v = ((pt.y / (1150 * tate)) + (floor(i / yoko) / tate));
                //texcoords[id*3 + j] = float2(u, v);
                facecoord[id*3 + j] = float2(u, v);
            }
        }
        
        if (count == 3) {
            faceBool[id] = 1;
            texcoords[id*3] = facecoord[id*3];
            texcoords[id*3 + 1] = facecoord[id*3 + 1];
            texcoords[id*3 + 2] = facecoord[id*3 + 2];
        }
        
    }
    
    //const auto vertexPoint4 = uniforms.transform * simd_float4(vertices[faces[int(id)]],1);
    //new_vertices[id] = vertexPoint4.xyz;
    
    //meshUniforms[id].vertexs = vertices[faces[int(id)]];
    //meshUniforms[id].normals = normals[faces[int(id)]];
}

//テクスチャ割り当て不可能なメッシュも含める
kernel void calcu5(constant float *vertices [[ buffer(0) ]],
                   constant float *normals [[ buffer(1) ]],
                   constant int *faces [[ buffer(2) ]],
                   device float2 *texcoords [[buffer(3)]],
                   device float3 *new_vertices [[ buffer(4) ]],
                   device float3 *new_normals [[ buffer(5) ]],
                   device int *new_faces [[ buffer(6)]],
                   device float2 *facecoord [[ buffer(7) ]],
                   constant float4x4 &uniforms [[ buffer(8) ]],
                   constant anchorUniforms &anchorUnifoms [[ buffer(9) ]],
                   constant float *depth [[ buffer(10) ]],
                   device int *trys [[ buffer(11) ]],
                   uint id [[ thread_position_in_grid ]])
{
    if (int(id) > anchorUnifoms.maxCount) {
        return;
    }
    
    float yoko = anchorUnifoms.yoko;
    float tate = anchorUnifoms.tate;
    float screenWidth = anchorUnifoms.screenWidth;
    float screenHeight = anchorUnifoms.screenHeight;
    
    //取得した画像，json
    for (int i = 0; i < anchorUnifoms.calcuCount; i++) {
        int count = 0;
        for (int j = 0; j < 3; j++) {
            new_faces[id*3 + j] = int(id*3 + j);
            new_vertices[id*3 + j] = mul(float3(vertices[faces[int(id*3 + j)]*3 + 0],
                                                vertices[faces[int(id*3 + j)]*3 + 1],
                                                vertices[faces[int(id*3 + j)]*3 + 2]),
                                         anchorUnifoms.transform);
            new_normals[id*3 + j] = float3(normals[faces[int(id*3 + j)]*3 + 0],
                                           normals[faces[int(id*3 + j)]*3 + 1],
                                           normals[faces[int(id*3 + j)]*3 + 2]);
            
            const auto normalizedDeviceCoordinate = clipPoint(new_vertices[id*3 + j],
                                                              matrix_float4x4(uniforms[i*4],uniforms[i*4+1],
                                                                              uniforms[i*4+2], uniforms[i*4+3]));
            const auto pt = float3((normalizedDeviceCoordinate.x + 1) * (screenWidth / 2),
                                   (-normalizedDeviceCoordinate.y + 1) * (screenHeight / 2),
                                   (1 - (-normalizedDeviceCoordinate.z + 1)));
            
            if (pt.x >= 0 && pt.x <= screenWidth && pt.y >= 0 && pt.y <= screenHeight && pt.z < 1.0) {
                const auto du = int(round((1 - pt.x / screenWidth) * 95));
                const auto dv = int(round((pt.y / screenHeight) * 127));
                const auto deptPosi_x = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j)];
                const auto deptPosi_y = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j) + 1];
                const auto deptPosi_z = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j) + 2];
                const auto diff = pow(new_vertices[id*3 + j].x - deptPosi_x, 2) + pow(new_vertices[id*3 + j].y - deptPosi_y, 2) + pow(new_vertices[id*3 + j].z - deptPosi_z, 2);
                
                if (diff < 0.04) {
                    count += 1;
                    const auto u = ((pt.x / (screenWidth * yoko))  + (fmod(i,yoko) / yoko));
                    const auto v = ((pt.y / (screenHeight * tate)) + (floor(i / yoko) / tate));
                    facecoord[id*3 + j] = float2(u, v);
                }
            }
        }
        
        if (count == 3) {
            texcoords[id*3] = facecoord[id*3];
            texcoords[id*3 + 1] = facecoord[id*3 + 1];
            texcoords[id*3 + 2] = facecoord[id*3 + 2];
            
            trys[0] += 1;
        }
    }
}

//テクスチャ割り当て可能なメッシュだけ含める
kernel void calcu50(constant float *vertices [[ buffer(0) ]],
                    constant float *normals [[ buffer(1) ]],
                    constant int *faces [[ buffer(2) ]],
                    device float2 *texcoords [[buffer(3)]],
                    device float3 *new_vertices [[ buffer(4) ]],
                    device float3 *new_normals [[ buffer(5) ]],
                    device int *new_faces [[ buffer(6)]],
                    device float2 *facecoord [[ buffer(7) ]],
                    constant float4x4 &uniforms [[ buffer(8) ]],
                    constant anchorUniforms &anchorUnifoms [[ buffer(9) ]],
                    constant float *depth [[ buffer(10) ]],
                    device int *trys [[ buffer(11) ]],
                    device int *picNum [[ buffer(12) ]],
                    uint id [[ thread_position_in_grid ]])
{
    if (int(id) > anchorUnifoms.maxCount) {
        return;
    }
    
    float yoko = anchorUnifoms.yoko;
    float tate = anchorUnifoms.tate;
    float screenWidth = anchorUnifoms.screenWidth;
    float screenHeight = anchorUnifoms.screenHeight;
    
    float3x3 kari_faces;
    float3x3 kari_vertices;
    float3x3 kari_normals;
    float3x2 kari_texcoords;
    
    //画像の枚数分繰り返し
    for (int i = 0; i < anchorUnifoms.calcuCount; i++) {
        int count = 0;
        
        for (int j = 0; j < 3; j++) {
            kari_faces[j] = int(id*3 + j);
            kari_vertices[j] = mul(float3(vertices[faces[int(id*3 + j)]*3 + 0],
                                          vertices[faces[int(id*3 + j)]*3 + 1],
                                          vertices[faces[int(id*3 + j)]*3 + 2]),
                                   anchorUnifoms.transform);
            kari_normals[j] = float3(normals[faces[int(id*3 + j)]*3 + 0],
                                     normals[faces[int(id*3 + j)]*3 + 1],
                                     normals[faces[int(id*3 + j)]*3 + 2]);
            
            const auto normalizedDeviceCoordinate = clipPoint(kari_vertices[j],
                                                              matrix_float4x4(uniforms[i*4],
                                                                              uniforms[i*4+1],
                                                                              uniforms[i*4+2],
                                                                              uniforms[i*4+3]));
            const auto pt = float3((normalizedDeviceCoordinate.x + 1) * (screenWidth / 2),
                                   (-normalizedDeviceCoordinate.y + 1) * (screenHeight / 2),
                                   (1 - (-normalizedDeviceCoordinate.z + 1)));
            
            if (pt.x >= 0 && pt.x <= screenWidth && pt.y >= 0 && pt.y <= screenHeight && pt.z < 1.0) {
                const auto du = int(round((1 - pt.x / screenWidth) * 95));
                const auto dv = int(round((pt.y / screenHeight) * 127));
                const auto deptPosi_x = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j)];
                const auto deptPosi_y = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j) + 1];
                const auto deptPosi_z = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j) + 2];
                const auto diff = pow(kari_vertices[j].x - deptPosi_x, 2) + pow(kari_vertices[j].y - deptPosi_y, 2) + pow(kari_vertices[j].z - deptPosi_z, 2);
                if (diff < 0.04) {
                    count += 1;
                    const auto u = ((pt.x / (screenWidth * yoko))  + (fmod(i,yoko) / yoko));
                    const auto v = ((pt.y / (screenHeight * tate)) + (floor(i / yoko) / tate));
                    kari_texcoords[j] = float2(u, v);
                } else {
                    count = 0;
                    break;
                }
            }
        }
        
        if (count == 3) {
            texcoords[id*3 + 0] = kari_texcoords[0];
            texcoords[id*3 + 1] = kari_texcoords[1];
            texcoords[id*3 + 2] = kari_texcoords[2];
            
            new_vertices[id*3 + 0] = kari_vertices[0];
            new_vertices[id*3 + 1] = kari_vertices[1];
            new_vertices[id*3 + 2] = kari_vertices[2];
            
            new_normals[id*3 + 0] = kari_normals[0];
            new_normals[id*3 + 1] = kari_normals[1];
            new_normals[id*3 + 2] = kari_normals[2];
            
            new_faces[id*3 + 0] = id*3 + 0;
            new_faces[id*3 + 1] = id*3 + 1;
            new_faces[id*3 + 2] = id*3 + 2;
            
            //trys[0] += 1;
            break;
        }
    }
}

kernel void choicePic_textureCalculate(constant float *vertices [[ buffer(0) ]],
                                       constant float *normals [[ buffer(1) ]],
                                       constant int *faces [[ buffer(2) ]],
                                       device float2 *texcoords [[buffer(3)]],
                                       device float3 *new_vertices [[ buffer(4) ]],
                                       device float3 *new_normals [[ buffer(5) ]],
                                       device int *new_faces [[ buffer(6)]],
                                       device float2 *facecoord [[ buffer(7) ]],
                                       constant float4x4 &uniforms [[ buffer(8) ]],
                                       constant anchorUniforms &anchorUnifoms [[ buffer(9) ]],
                                       constant float *depth [[ buffer(10) ]],
                                       device int *trys [[ buffer(11) ]],
                                       constant int *picNum [[ buffer(12) ]],
                                       device int *idArray [[ buffer(13) ]],
                                       uint id [[ thread_position_in_grid ]])
{
    if (int(id) > anchorUnifoms.maxCount) {
        return;
    }
    
    float yoko = anchorUnifoms.yoko;
    float tate = anchorUnifoms.tate;
    float screenWidth = anchorUnifoms.screenWidth;
    float screenHeight = anchorUnifoms.screenHeight;
    
    float3x3 temp_faces;
    float3x3 temp_vertices;
    float3x3 temp_normals;
    float3x2 temp_texcoords;
    
    //画像の枚数分繰り返し
    for (int num = 0; num < anchorUnifoms.picNumCount; num++) {
        int i = picNum[num];
        trys[num] = i;
        
        if (idArray[id] == 0) {
            
            //ポリゴンの３点について調べる
            int count = 0;
            for (int j = 0; j < 3; j++) {
                temp_faces[j] = int(id*3 + j);
                float4 worldPoint4 = anchorUnifoms.transform * float4(vertices[faces[int(id*3 + j)]*3 + 0],
                                                                      vertices[faces[int(id*3 + j)]*3 + 1],
                                                                      vertices[faces[int(id*3 + j)]*3 + 2],
                                                                      1.0);
                temp_vertices[j] = float3(worldPoint4.x, worldPoint4.y, worldPoint4.z);
                temp_normals[j] = float3(normals[faces[int(id*3 + j)]*3 + 0],
                                         normals[faces[int(id*3 + j)]*3 + 1],
                                         normals[faces[int(id*3 + j)]*3 + 2]);
                
                const auto clipSpacePosition = matrix_float4x4(uniforms[i*4],
                                                               uniforms[i*4+1],
                                                               uniforms[i*4+2],
                                                               uniforms[i*4+3]) * simd_float4(temp_vertices[j], 1.0);
                const auto normalizedDeviceCoordinate = clipSpacePosition / clipSpacePosition.w;
                
                const auto pt = float3((normalizedDeviceCoordinate.x + 1) * (screenWidth / 2),
                                       (-normalizedDeviceCoordinate.y + 1) * (screenHeight / 2),
                                       (1 - (-normalizedDeviceCoordinate.z + 1)));
                
                if (pt.x >= 0 && pt.x <= screenWidth && pt.y >= 0 && pt.y <= screenHeight && pt.z < 1.0) {
                    const auto du = int(round((1 - pt.x / screenWidth) * 95));
                    const auto dv = int(round((pt.y / screenHeight) * 127));
                    const auto deptPosi_x = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j)];
                    const auto deptPosi_y = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j) + 1];
                    const auto deptPosi_z = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j) + 2];
                    const auto diff = pow(temp_vertices[j].x - deptPosi_x, 2) + pow(temp_vertices[j].y - deptPosi_y, 2) + pow(temp_vertices[j].z - deptPosi_z, 2);
                    if (diff < 0.04) {
                        count += 1;
                        const auto u = ((pt.x / (screenWidth * yoko))  + (fmod(i,yoko) / yoko));
                        const auto v = ((pt.y / (screenHeight * tate)) + (floor(i / yoko) / tate));
                        temp_texcoords[j] = float2(u, v);
                    } else {
                        count = 0;
                        break;
                    }
                }
            }
            
            //調べた３点が条件を満たせば計算結果を格納
            if (count == 3) {
                
                texcoords[id*3 + 0] = temp_texcoords[0];
                texcoords[id*3 + 1] = temp_texcoords[1];
                texcoords[id*3 + 2] = temp_texcoords[2];
                
                new_vertices[id*3 + 0] = temp_vertices[0];
                new_vertices[id*3 + 1] = temp_vertices[1];
                new_vertices[id*3 + 2] = temp_vertices[2];
                
                new_normals[id*3 + 0] = temp_normals[0];
                new_normals[id*3 + 1] = temp_normals[1];
                new_normals[id*3 + 2] = temp_normals[2];
                
                new_faces[id*3 + 0] = id*3 + 0;
                new_faces[id*3 + 1] = id*3 + 1;
                new_faces[id*3 + 2] = id*3 + 2;
                
                idArray[id] = 1;
                
                break;
            }
        }
    }
    
}

//メッシュを結合したバッファで計算
kernel void all_textureCalculate(constant float3 *vertices [[ buffer(0) ]],
                                 constant float3 *normals [[ buffer(1) ]],
                                 constant int *faces [[ buffer(2) ]],
                                 constant int *sepaVertices [[ buffer(3) ]],
                                 constant int *sepaFaces [[ buffer(4) ]],
                                 device float2 *texcoords [[buffer(5)]],
                                 device float3 *new_vertices [[ buffer(6) ]],
                                 device float3 *new_normals [[ buffer(7) ]],
                                 device int *new_faces [[ buffer(8)]],
                                 constant anchorUniforms &anchorUnifoms [[ buffer(9) ]],
                                 constant float4x4 &uniforms [[ buffer(10) ]],
                                 constant float4x4 &transforms [[ buffer(11) ]],
                                 constant float *depth [[ buffer(12) ]],
                                 constant int *picNum [[ buffer(13) ]],
                                 constant int *sepaPicNum [[ buffer(14) ]],
                                 uint id [[ thread_position_in_grid ]])
{
    if (int(id) > anchorUnifoms.maxCount) {
        return;
    }
    
    float yoko = anchorUnifoms.yoko;
    float tate = anchorUnifoms.tate;
    float screenWidth = anchorUnifoms.screenWidth;
    float screenHeight = anchorUnifoms.screenHeight;
    
    float3x3 temp_faces;
    float3x3 temp_vertices;
    float3x3 temp_normals;
    float3x2 temp_texcoords;
    
    //idに対応するメッシュ番号
    int meshID = sepaFaces[id];
    int min = 0;

    //画像の枚数分繰り返し
    if (meshID != 0) {
        min = sepaPicNum[meshID-1];
    }
    
    for (int picID = min; picID < sepaPicNum[meshID]; picID++) {
        int i = picNum[picID]; //パラメータ番号
        
        //ポリゴンの３点について調べる
        int count = 0;
        for (int j = 0; j < 3; j++) {
            temp_faces[j] = int(id*3 + j);
            
            if (meshID != 0) {
                float4 worldPoint4 = matrix_float4x4(transforms[meshID*4],
                                                     transforms[meshID*4+1],
                                                     transforms[meshID*4+2],
                                                     transforms[meshID*4+3]) * float4(vertices[sepaVertices[meshID-1] + faces[int(id*3 + j)]], 1.0);
                temp_vertices[j] = float3(worldPoint4.x, worldPoint4.y, worldPoint4.z);
                //new_vertices[id*3 + j] = float3(worldPoint4.x, worldPoint4.y, worldPoint4.z);
                temp_normals[j] = float3(normals[sepaVertices[meshID-1] + faces[int(id*3 + j)]]);
            } else {
                float4 worldPoint4 = matrix_float4x4(transforms[meshID*4],
                                                     transforms[meshID*4+1],
                                                     transforms[meshID*4+2],
                                                     transforms[meshID*4+3]) * float4(vertices[faces[int(id*3 + j)]], 1.0);
                temp_vertices[j] = float3(worldPoint4.x, worldPoint4.y, worldPoint4.z);
                //new_vertices[id*3 + j] = float3(worldPoint4.x, worldPoint4.y, worldPoint4.z);
                temp_normals[j] = float3(normals[faces[int(id*3 + j)]]);
            }
            
            const auto clipSpacePosition = matrix_float4x4(uniforms[i*4],
                                                           uniforms[i*4+1],
                                                           uniforms[i*4+2],
                                                           uniforms[i*4+3]) * simd_float4(temp_vertices[j], 1.0);
            const auto normalizedDeviceCoordinate = clipSpacePosition / clipSpacePosition.w;
            const auto pt = float3((normalizedDeviceCoordinate.x + 1) * (screenWidth / 2),
                                   (-normalizedDeviceCoordinate.y + 1) * (screenHeight / 2),
                                   (1 - (-normalizedDeviceCoordinate.z + 1)));
            if (pt.x >= 0 && pt.x <= screenWidth && pt.y >= 0 && pt.y <= screenHeight && pt.z < 1.0) {
                const auto du = int(round((1 - pt.x / screenWidth) * 95));
                const auto dv = int(round((pt.y / screenHeight) * 127));
                const auto deptPosi_x = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j)];
                const auto deptPosi_y = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j) + 1];
                const auto deptPosi_z = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j) + 2];
                const auto diff = pow(temp_vertices[j].x - deptPosi_x, 2) + pow(temp_vertices[j].y - deptPosi_y, 2) + pow(temp_vertices[j].z - deptPosi_z, 2);
                if (diff < 0.04) {
                    count += 1;
                    const auto u = ((pt.x / (screenWidth * yoko))  + (fmod(i,yoko) / yoko));
                    const auto v = ((pt.y / (screenHeight * tate)) + (floor(i / yoko) / tate));
                    temp_texcoords[j] = float2(u, v);
                } else {
                    count = 0;
                    break;
                }
            }
        }

        //調べた３点が条件を満たせば計算結果を格納
        if (count == 3) {

            texcoords[id*3 + 0] = temp_texcoords[0];
            texcoords[id*3 + 1] = temp_texcoords[1];
            texcoords[id*3 + 2] = temp_texcoords[2];

            new_vertices[id*3 + 0] = temp_vertices[0];
            new_vertices[id*3 + 1] = temp_vertices[1];
            new_vertices[id*3 + 2] = temp_vertices[2];

            new_normals[id*3 + 0] = temp_normals[0];
            new_normals[id*3 + 1] = temp_normals[1];
            new_normals[id*3 + 2] = temp_normals[2];

            new_faces[id*3 + 0] = id*3 + 0;
            new_faces[id*3 + 1] = id*3 + 1;
            new_faces[id*3 + 2] = id*3 + 2;

            break;
        }
    }

}


static simd_float3 make_naisin(simd_float3 A, simd_float3 B, simd_float3 C) {
    float a = A.x;
    float b = A.y;
    float c = A.z;
    float d = B.x;
    float e = B.y;
    float f = B.z;
    float g = C.x;
    float h = C.y;
    float i = C.z;
    
    
    float a_size = sqrt(pow(d-g, 2.0) + pow(e-h, 2.0) + pow(f-i, 2.0));
    float b_size = sqrt(pow(g-a, 2.0) + pow(h-b, 2.0) + pow(i-c, 2.0));
    float c_size = sqrt(pow(d-a, 2.0) + pow(e-b, 2.0) + pow(f-c, 2.0));
    
    float x = (a_size * a + b_size * d + c_size * g) / (a_size + b_size + c_size);
    float y = (a_size * b + b_size * e + c_size * h) / (a_size + b_size + c_size);
    float z = (a_size * c + b_size * f + c_size * i) / (a_size + b_size + c_size);
    
    return simd_float3(x, y, z);
}

kernel void textureCalculate(constant float *vertices [[ buffer(0) ]],
                             constant float *normals [[ buffer(1) ]],
                             constant int *faces [[ buffer(2) ]],
                             device float2 *texcoords [[buffer(3)]],
                             device float3 *new_vertices [[ buffer(4) ]],
                             device float3 *new_normals [[ buffer(5) ]],
                             device int *new_faces [[ buffer(6)]],
                             device float2 *facecoord [[ buffer(7) ]],
                             constant float4x4 &uniforms [[ buffer(8) ]],
                             constant anchorUniforms &anchorUnifoms [[ buffer(9) ]],
                             constant float *depth [[ buffer(10) ]],
                             device int *trys [[ buffer(11) ]],
                             constant int *picNum [[ buffer(12) ]],
                             uint id [[ thread_position_in_grid ]])
{
    if (int(id) > anchorUnifoms.maxCount) {
        return;
    }
    
    float yoko = anchorUnifoms.yoko;
    float tate = anchorUnifoms.tate;
    float screenWidth = anchorUnifoms.screenWidth;
    float screenHeight = anchorUnifoms.screenHeight;
    
    float3x3 kari_faces;
    float3x3 kari_vertices;
    float3x3 kari_normals;
    float3x2 kari_texcoords;
    
    bool flag = false;
    
    for (int num = 0; num < anchorUnifoms.picNumCount; num++) {
        int i = picNum[num];
        trys[num] = i;
        
        int count = 0;
        flag = false;
        
        //中心点
        simd_float3 xyz = make_naisin(simd_float3(vertices[faces[int(id*3 + 0)]*3 + 0],
                                                  vertices[faces[int(id*3 + 0)]*3 + 1],
                                                  vertices[faces[int(id*3 + 0)]*3 + 2]),
                                      simd_float3(vertices[faces[int(id*3 + 1)]*3 + 0],
                                                  vertices[faces[int(id*3 + 1)]*3 + 1],
                                                  vertices[faces[int(id*3 + 1)]*3 + 2]),
                                      simd_float3(vertices[faces[int(id*3 + 2)]*3 + 0],
                                                  vertices[faces[int(id*3 + 2)]*3 + 1],
                                                  vertices[faces[int(id*3 + 2)]*3 + 2]));
        const auto point = mul(xyz, anchorUnifoms.transform);
        const auto normalizedDeviceCoordinate = clipPoint(point, matrix_float4x4(uniforms[i*4],
                                                                                 uniforms[i*4+1],
                                                                                 uniforms[i*4+2],
                                                                                 uniforms[i*4+3]));
        const auto pt = float3((normalizedDeviceCoordinate.x + 1) * (screenWidth / 2),
                               (-normalizedDeviceCoordinate.y + 1) * (screenHeight / 2),
                               (1 - (-normalizedDeviceCoordinate.z + 1)));
        if (pt.x >= 0 && pt.x <= screenWidth && pt.y >= 0 && pt.y <= screenHeight && pt.z < 1.0) {
            const auto du = int(round((1 - pt.x / screenWidth) * 95));
            const auto dv = int(round((pt.y / screenHeight) * 127));
            const auto deptPosi_x = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv)];
            const auto deptPosi_y = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv) + 1];
            const auto deptPosi_z = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv) + 2];
            const auto diff = pow(point.x - deptPosi_x, 2.0) + pow(point.y - deptPosi_y, 2.0) + pow(point.z - deptPosi_z, 2.0);
            if (diff < 0.04) {
                flag = true;
            }
        }
        
        if (flag == true) {
            for (int j = 0; j < 3; j++) {
                kari_faces[j] = int(id*3 + j);
                kari_vertices[j] = mul(float3(vertices[faces[int(id*3 + j)]*3 + 0],
                                              vertices[faces[int(id*3 + j)]*3 + 1],
                                              vertices[faces[int(id*3 + j)]*3 + 2]),
                                       anchorUnifoms.transform);
                kari_normals[j] = float3(normals[faces[int(id*3 + j)]*3 + 0],
                                         normals[faces[int(id*3 + j)]*3 + 1],
                                         normals[faces[int(id*3 + j)]*3 + 2]);
                
                const auto normalizedDeviceCoordinate = clipPoint(kari_vertices[j],
                                                                  matrix_float4x4(uniforms[i*4],
                                                                                  uniforms[i*4+1],
                                                                                  uniforms[i*4+2],
                                                                                  uniforms[i*4+3]));
                const auto pt = float3((normalizedDeviceCoordinate.x + 1) * (screenWidth / 2),
                                       (-normalizedDeviceCoordinate.y + 1) * (screenHeight / 2),
                                       (1 - (-normalizedDeviceCoordinate.z + 1)));
                if (pt.x >= 0 && pt.x <= screenWidth && pt.y >= 0 && pt.y <= screenHeight && pt.z < 1.0) {
                    const auto du = int(round((1 - pt.x / screenWidth) * 95));
                    const auto dv = int(round((pt.y / screenHeight) * 127));
                    const auto deptPosi_x = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j)];
                    const auto deptPosi_y = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j) + 1];
                    const auto deptPosi_z = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + j) + 2];
                    const auto diff = pow(kari_vertices[j].x - deptPosi_x, 2) + pow(kari_vertices[j].y - deptPosi_y, 2) + pow(kari_vertices[j].z - deptPosi_z, 2);
                    if (diff < 0.04) {
                        count += 1;
                        const auto u = ((pt.x / (screenWidth * yoko))  + (fmod(i,yoko) / yoko));
                        const auto v = ((pt.y / (screenHeight * tate)) + (floor(i / yoko) / tate));
                        kari_texcoords[j] = float2(u, v);
                    } else {
                        count = 0;
                        break;
                    }
                }
            }
            
            if (count == 3) {
                texcoords[id*3 + 0] = kari_texcoords[0];
                texcoords[id*3 + 1] = kari_texcoords[1];
                texcoords[id*3 + 2] = kari_texcoords[2];
                
                new_vertices[id*3 + 0] = kari_vertices[0];
                new_vertices[id*3 + 1] = kari_vertices[1];
                new_vertices[id*3 + 2] = kari_vertices[2];
                
                new_normals[id*3 + 0] = kari_normals[0];
                new_normals[id*3 + 1] = kari_normals[1];
                new_normals[id*3 + 2] = kari_normals[2];
                
                new_faces[id*3 + 0] = id*3 + 0;
                new_faces[id*3 + 1] = id*3 + 1;
                new_faces[id*3 + 2] = id*3 + 2;
                
                break;
            }
        }
        
    }
    
}


kernel void calcu500(constant float *vertices [[ buffer(0) ]],
                    constant float *normals [[ buffer(1) ]],
                    constant int *faces [[ buffer(2) ]],
                    device float2 *texcoords [[buffer(3)]],
                    device float3 *new_vertices [[ buffer(4) ]],
                    device float3 *new_normals [[ buffer(5) ]],
                    device int *new_faces [[ buffer(6)]],
                    device float2 *facecoord [[ buffer(7) ]],
                    constant float4x4 &uniforms [[ buffer(8) ]],
                    constant anchorUniforms &anchorUnifoms [[ buffer(9) ]],
                    constant float *depth [[ buffer(10) ]],
                    device int *trys [[ buffer(11) ]],
                    device int *picNum [[ buffer(12) ]],
                    uint id [[ thread_position_in_grid ]])
{
    if (int(id) > anchorUnifoms.maxCount) {
        return;
    }
    
    float yoko = anchorUnifoms.yoko;
    float tate = anchorUnifoms.tate;
    float screenWidth = anchorUnifoms.screenWidth;
    float screenHeight = anchorUnifoms.screenHeight;
    
    float3x3 kari_faces;
    float3x3 kari_vertices;
    float3x3 kari_normals;
    float3x2 kari_texcoords;
    
    //画像の枚数分繰り返し
    for (int i = 0; i < anchorUnifoms.calcuCount; i++) {
        int count = 0;
        bool meshFlag = false;
        
        //0番目の面
        kari_faces[0] = int(id*3 + 0);
        kari_vertices[0] = mul(float3(vertices[faces[int(id*3 + 0)]*3 + 0],
                                      vertices[faces[int(id*3 + 0)]*3 + 1],
                                      vertices[faces[int(id*3 + 0)]*3 + 2]),
                               anchorUnifoms.transform);
        kari_normals[0] = float3(normals[faces[int(id*3 + 0)]*3 + 0],
                                 normals[faces[int(id*3 + 0)]*3 + 1],
                                 normals[faces[int(id*3 + 0)]*3 + 2]);
        
        const auto normalizedDeviceCoordinate0 = clipPoint(kari_vertices[0],
                                                          matrix_float4x4(uniforms[i*4],
                                                                          uniforms[i*4+1],
                                                                          uniforms[i*4+2],
                                                                          uniforms[i*4+3]));
        const auto pt0 = float3((normalizedDeviceCoordinate0.x + 1) * (screenWidth / 2),
                               (-normalizedDeviceCoordinate0.y + 1) * (screenHeight / 2),
                               (1 - (-normalizedDeviceCoordinate0.z + 1)));
        if (pt0.x >= 0 && pt0.x <= screenWidth && pt0.y >= 0 && pt0.y <= screenHeight && pt0.z < 1.0) {
            const auto du = int(round((1 - pt0.x / screenWidth) * 95));
            const auto dv = int(round((pt0.y / screenHeight) * 127));
            const auto deptPosi_x = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + 0)];
            const auto deptPosi_y = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + 0) + 1];
            const auto deptPosi_z = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + 0) + 2];
            const auto diff = pow(kari_vertices[0].x - deptPosi_x, 2) + pow(kari_vertices[0].y - deptPosi_y, 2) + pow(kari_vertices[0].z - deptPosi_z, 2);
            if (diff < 0.04) {
                const auto u = ((pt0.x / (screenWidth * yoko))  + (fmod(i,yoko) / yoko));
                const auto v = ((pt0.y / (screenHeight * tate)) + (floor(i / yoko) / tate));
                kari_texcoords[0] = float2(u, v);
                
                count += 1;
                meshFlag = true;
            } else {
                count = 0;
                continue;
            }
        }
        
        if (meshFlag == true) {
            //1番目の面
            kari_faces[1] = int(id*3 + 1);
            kari_vertices[1] = mul(float3(vertices[faces[int(id*3 + 1)]*3 + 0],
                                          vertices[faces[int(id*3 + 1)]*3 + 1],
                                          vertices[faces[int(id*3 + 1)]*3 + 2]),
                                   anchorUnifoms.transform);
            kari_normals[1] = float3(normals[faces[int(id*3 + 1)]*3 + 0],
                                     normals[faces[int(id*3 + 1)]*3 + 1],
                                     normals[faces[int(id*3 + 1)]*3 + 2]);
            
            const auto normalizedDeviceCoordinate1 = clipPoint(kari_vertices[1],
                                                               matrix_float4x4(uniforms[i*4],
                                                                               uniforms[i*4+1],
                                                                               uniforms[i*4+2],
                                                                               uniforms[i*4+3]));
            const auto pt1 = float3((normalizedDeviceCoordinate1.x + 1) * (screenWidth / 2),
                                    (-normalizedDeviceCoordinate1.y + 1) * (screenHeight / 2),
                                    (1 - (-normalizedDeviceCoordinate1.z + 1)));
            if (pt1.x >= 0 && pt1.x <= screenWidth && pt1.y >= 0 && pt1.y <= screenHeight && pt1.z < 1.0) {
                const auto du = int(round((1 - pt1.x / screenWidth) * 95));
                const auto dv = int(round((pt1.y / screenHeight) * 127));
                const auto deptPosi_x = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + 1)];
                const auto deptPosi_y = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + 1) + 1];
                const auto deptPosi_z = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + 1) + 2];
                const auto diff = pow(kari_vertices[1].x - deptPosi_x, 2) + pow(kari_vertices[1].y - deptPosi_y, 2) + pow(kari_vertices[1].z - deptPosi_z, 2);
                if (diff < 0.04) {
                    count += 1;
                    const auto u = ((pt1.x / (screenWidth * yoko))  + (fmod(i,yoko) / yoko));
                    const auto v = ((pt1.y / (screenHeight * tate)) + (floor(i / yoko) / tate));
                    kari_texcoords[1] = float2(u, v);
                } else {
                    count = 0;
                    continue;
                }
            }
            
            //2番目の面
            kari_faces[2] = int(id*3 + 2);
            kari_vertices[2] = mul(float3(vertices[faces[int(id*3 + 2)]*3 + 0],
                                          vertices[faces[int(id*3 + 2)]*3 + 1],
                                          vertices[faces[int(id*3 + 2)]*3 + 2]),
                                   anchorUnifoms.transform);
            kari_normals[2] = float3(normals[faces[int(id*3 + 2)]*3 + 0],
                                     normals[faces[int(id*3 + 2)]*3 + 1],
                                     normals[faces[int(id*3 + 2)]*3 + 2]);
            
            const auto normalizedDeviceCoordinate2 = clipPoint(kari_vertices[2],
                                                               matrix_float4x4(uniforms[i*4],
                                                                               uniforms[i*4+1],
                                                                               uniforms[i*4+2],
                                                                               uniforms[i*4+3]));
            const auto pt2 = float3((normalizedDeviceCoordinate2.x + 1) * (screenWidth / 2),
                                    (-normalizedDeviceCoordinate2.y + 1) * (screenHeight / 2),
                                    (1 - (-normalizedDeviceCoordinate2.z + 1)));
            if (pt2.x >= 0 && pt2.x <= screenWidth && pt2.y >= 0 && pt2.y <= screenHeight && pt2.z < 1.0) {
                const auto du = int(round((1 - pt2.x / screenWidth) * 95));
                const auto dv = int(round((pt2.y / screenHeight) * 127));
                const auto deptPosi_x = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + 2)];
                const auto deptPosi_y = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + 2) + 1];
                const auto deptPosi_z = depth[i*anchorUnifoms.depthCount*3 + 3*(du*128 + dv + 2) + 2];
                const auto diff = pow(kari_vertices[2].x - deptPosi_x, 2) + pow(kari_vertices[2].y - deptPosi_y, 2) + pow(kari_vertices[2].z - deptPosi_z, 2);
                if (diff < 0.04) {
                    count += 1;
                    const auto u = ((pt2.x / (screenWidth * yoko))  + (fmod(i,yoko) / yoko));
                    const auto v = ((pt2.y / (screenHeight * tate)) + (floor(i / yoko) / tate));
                    kari_texcoords[2] = float2(u, v);
                } else {
                    count = 0;
                    continue;
                }
            }
            
            
            if (count == 3) {
                texcoords[id*3 + 0] = kari_texcoords[0];
                texcoords[id*3 + 1] = kari_texcoords[1];
                texcoords[id*3 + 2] = kari_texcoords[2];
                
                new_vertices[id*3 + 0] = kari_vertices[0];
                new_vertices[id*3 + 1] = kari_vertices[1];
                new_vertices[id*3 + 2] = kari_vertices[2];
                
                new_normals[id*3 + 0] = kari_normals[0];
                new_normals[id*3 + 1] = kari_normals[1];
                new_normals[id*3 + 2] = kari_normals[2];
                
                new_faces[id*3 + 0] = id*3 + 0;
                new_faces[id*3 + 1] = id*3 + 1;
                new_faces[id*3 + 2] = id*3 + 2;
                
                break;
            }
        }
    }
}

kernel void Judge (constant float *vertices [[ buffer(0) ]],
                   constant int *faces [[ buffer(1) ]],
                   device float3 *judges [[ buffer(2) ]],
                   constant float4x4 &uniforms [[ buffer(3) ]],
                   device realAnchorUniforms &anchorUnifoms [[ buffer(10) ]],
                   uint id [[ thread_position_in_grid ]])
{
    if (int(id) > anchorUnifoms.maxCount) {
        return;
    }
    
    for (int i = 0; i < anchorUnifoms.calcuCount; i++) {
        int count = 0;
        for (int j = 0; j < 3; j++) {
            float3 point = mul(float3(vertices[faces[int(id*3 + j)]*3 + 0],
                                      vertices[faces[int(id*3 + j)]*3 + 1],
                                      vertices[faces[int(id*3 + j)]*3 + 2]),
                               anchorUnifoms.transform);
            
            const auto normalizedDeviceCoordinate = clipPoint(point, matrix_float4x4(uniforms[i*4],uniforms[i*4+1],uniforms[i*4+2], uniforms[i*4+3]));
            const auto pt = float3((normalizedDeviceCoordinate.x + 1) * (834 / 2),
                                        (-normalizedDeviceCoordinate.y + 1) * (1150 / 2),
                                        (1 - (-normalizedDeviceCoordinate.z + 1)));
            if (pt.x >= 0 && pt.x <= 834 && pt.y >= 0 && pt.y <= 1150 && pt.z < 1.0) {
                count += 1;
            }
        }
        
        if (count == 1 || count == 2) {
            judges[anchorUnifoms.currentIndex*3] = mul(float3(vertices[faces[int(id*3 + 0)]*3 + 0],
                                                              vertices[faces[int(id*3 + 0)]*3 + 1],
                                                              vertices[faces[int(id*3 + 0)]*3 + 2]),
                                                       anchorUnifoms.transform);
            judges[anchorUnifoms.currentIndex*3 + 1] = mul(float3(vertices[faces[int(id*3 + 1)]*3 + 0],
                                                                  vertices[faces[int(id*3 + 1)]*3 + 1],
                                                                  vertices[faces[int(id*3 + 1)]*3 + 2]),
                                                           anchorUnifoms.transform);
            judges[anchorUnifoms.currentIndex*3 + 2] = mul(float3(vertices[faces[int(id*3 + 2)]*3 + 0],
                                                                  vertices[faces[int(id*3 + 2)]*3 + 1],
                                                                  vertices[faces[int(id*3 + 2)]*3 + 2]),
                                                           anchorUnifoms.transform);
            anchorUnifoms.currentIndex += 1;
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
kernel void meshCalculate(constant float *vertices [[ buffer(0) ]],
                          constant int *faces [[ buffer(1) ]],
                          device float3 *new_vertices [[ buffer(2) ]],
                          device int *new_faces [[ buffer(3)]],
                          device float2 *texcoords [[buffer(4)]],
                          constant realAnchorUniforms &anchorUnifoms [[ buffer(10) ]],
                          //device float3 *trys [[ buffer(11) ]],
                          uint id [[ thread_position_in_grid ]])
{
    if (int(id) > anchorUnifoms.maxCount) {
        return;
    }
    
    new_faces[id*3] = int(id*3);
    new_faces[id*3 + 1] = int(id*3 + 1);
    new_faces[id*3 + 2] = int(id*3 + 2);
    
    new_vertices[id*3] = float3(vertices[faces[int(id*3)]*3],
                                vertices[faces[int(id*3)]*3 + 1],
                                vertices[faces[int(id*3)]*3 + 2]);
    new_vertices[id*3 + 1] = float3(vertices[faces[int(id*3 + 1)]*3],
                                    vertices[faces[int(id*3 + 1)]*3 + 1],
                                    vertices[faces[int(id*3 + 1)]*3 + 2]);
    new_vertices[id*3 + 2] = float3(vertices[faces[int(id*3 + 2)]*3],
                                    vertices[faces[int(id*3 + 2)]*3 + 1],
                                    vertices[faces[int(id*3 + 2)]*3 + 2]);
    
//    texcoords[id*3] = float2(0, 0);
//    texcoords[id*3 + 1] = float2(0, 0);
//    texcoords[id*3 + 2] = float2(0, 0);
}

vertex void meshCalculate2(uint id [[ vertex_id ]],
                           constant float *vertices [[ buffer(0) ]],
                           constant int *faces [[ buffer(1) ]],
                           device MeshUniforms *meshUniforms [[ buffer(7) ]],
                           constant realAnchorUniforms &anchorUnifoms [[ buffer(6) ]])
{
//    if (int(id) > anchorUnifoms.maxCount) {
//        return;
//    }
    
    const auto currentIndex = id; //int(id / 3); //(anchorUnifoms.currentIndex + id) % anchorUnifoms.maxCount;
    meshUniforms[currentIndex].index = currentIndex;
    meshUniforms[currentIndex].originIndex = faces[id];
    meshUniforms[currentIndex].faceIndex = int3(faces[int(id)], faces[int(id+1)], faces[int(id+2)]);
    
//    meshUniforms[currentIndex].faces = int(id*3);
//    meshUniforms[currentIndex + 1].faces = int(id*3 + 1);
//    meshUniforms[currentIndex + 2].faces = int(id*3 + 2);
    
    meshUniforms[currentIndex].vertex1 = mul(float3(vertices[faces[id]*3 + 0],
                                                    vertices[faces[id]*3 + 1],
                                                    vertices[faces[id]*3 + 2]),
                                             anchorUnifoms.transform);
//    meshUniforms[currentIndex].vertex2 = mul(float3(vertices[faces[int(id*3 + 1)]*3 + 0],
//                                                    vertices[faces[int(id*3 + 1)]*3 + 1],
//                                                    vertices[faces[int(id*3 + 1)]*3 + 2]),
//                                             anchorUnifoms.transform);
//    meshUniforms[currentIndex].vertex3 = mul(float3(vertices[faces[int(id*3 + 2)]*3 + 0],
//                                                    vertices[faces[int(id*3 + 2)]*3 + 1],
//                                                    vertices[faces[int(id*3 + 2)]*3 + 2]),
//                                             anchorUnifoms.transform);
    
    meshUniforms[currentIndex].color = float4(0,0,1.0,0.3);
    
//    new_faces[id*3] = int(id*3);
//    new_faces[id*3 + 1] = int(id*3 + 1);
//    new_faces[id*3 + 2] = int(id*3 + 2);
//
//    new_vertices[id*3] = float3(vertices[faces[int(id*3)]*3],
//                                vertices[faces[int(id*3)]*3 + 1],
//                                vertices[faces[int(id*3)]*3 + 2]);
//    new_vertices[id*3 + 1] = float3(vertices[faces[int(id*3 + 1)]*3],
//                                    vertices[faces[int(id*3 + 1)]*3 + 1],
//                                    vertices[faces[int(id*3 + 1)]*3 + 2]);
//    new_vertices[id*3 + 2] = float3(vertices[faces[int(id*3 + 2)]*3],
//                                    vertices[faces[int(id*3 + 2)]*3 + 1],
//                                    vertices[faces[int(id*3 + 2)]*3 + 2]);
}
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
struct MeshVertexOut {
    float4 position [[position]]; //特徴点の３次元座標
    float pointSize [[point_size]];
    float4 color; //特徴点の色情報
};
struct MeshFragmentOut {
    float depth [[depth(any)]]; //深度情報
    float4 color; //色情報
};

vertex MeshVertexOut meshVertex(uint id [[vertex_id]],
                                constant MeshUniforms *meshUniforms [[ buffer(7) ]],
                                constant realAnchorUniforms &anchorUnifoms [[ buffer(6) ]]) {
    
    const auto position = meshUniforms[id].vertex1;
    float4 projectedPosition = anchorUnifoms.viewProjectionMatrix * float4(position, 1.0);
    projectedPosition /= projectedPosition.w;
    
    // prepare for output
    MeshVertexOut out;
    out.position = projectedPosition;
    out.pointSize = 10.0;
    out.color = meshUniforms[id].color; //float4(0, 0, 1.0, 1.0);
    
    return out;
}

fragment MeshFragmentOut meshFragment(MeshVertexOut in [[stage_in]],
                                 const float2 coords [[point_coord]]) {
    // we draw within a circle
    //特徴点の形を四角形から円形にしている
//    const float distSquared = length_squared(coords - float2(0.5));
//    if (in.color.a == 0 || distSquared > 0.25) {
//        discard_fragment(); //当該のピクセルを放棄
//    }

    MeshFragmentOut out;

    // scale depth values to a range compatible
    // with depth buffer rendered by SceneKit
    out.depth = 1.0 + in.position.z;
    out.color = in.color;

    return out;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

struct ColorInOut {
    float4 position [[position]]; //特徴点の３次元座標
    float2 texCoord;
    int visible;
};

vertex ColorInOut meshVertex10(const device float4 *positions [[ buffer(0)]],
                                uint id [[ vertex_id ]]) {
    
    ColorInOut out;
    out.position = positions[id];
    return out;
}

fragment float4 meshFragment10(ColorInOut in [[ stage_in ]]) {
    return float4(1,0,0,0.5);
}

vertex ColorInOut meshVertex100(constant float *vertices [[ buffer(1) ]],
                                constant int *faces [[ buffer(2) ]],
                                constant AnchorUniforms &anchorUnifoms [[ buffer(3) ]],
                                constant float4x4 *uniforms [[ buffer(4) ]],
                                uint id [[ vertex_id ]]) {
    
    //メッシュの頂点をワールド座標系に変換
    const auto position = mul(float3(vertices[faces[id]*3 + 0],
                                     vertices[faces[id]*3 + 1],
                                     vertices[faces[id]*3 + 2]),
                              anchorUnifoms.transform);;
    
    float screenWidth = anchorUnifoms.screenWidth;
    float screenHeight = anchorUnifoms.screenHeight;
    
    ColorInOut out;
    
    if (anchorUnifoms.calcuCount > 0) {
        float4 projectedPosition = anchorUnifoms.viewProjectionMatrix * float4(position, 1.0);
        projectedPosition /= projectedPosition.w; //必要
        
    //    const auto pt = float3((projectedPosition.x + 1) * (834 / 2),
    //                           (-projectedPosition.y + 1) * (1150 / 2),
    //                           (1 - (-projectedPosition.z + 1)));
        
        if (abs(projectedPosition.x) >= 5.0 || abs(projectedPosition.y >= 5.0 || projectedPosition.z > 1.0)) {
            out.visible = 1;
        } else {
            out.visible = 2;
            out.position = projectedPosition;
        //const auto new_tex = float2(pt.y/1194, 1 - pt.x/834);
        //out.texCoord = float2(pt.x/834, pt.y/1150);
        }
        
        //変換した頂点が画面上に位置するかを判定
        if (out.visible == 2) {
            for (int i = 0; i < anchorUnifoms.calcuCount; i++) {
                const auto normalizedDeviceCoordinate = clipPoint(position, uniforms[i]);
                const auto pt = float3((normalizedDeviceCoordinate.x + 1) * (screenWidth / 2),
                                       (-normalizedDeviceCoordinate.y + 1) * (screenHeight / 2),
                                       (1 - (-normalizedDeviceCoordinate.z + 1)));
                
                if (pt.x >= 0 && pt.x <= screenWidth && pt.y >= 0 && pt.y <= screenHeight && pt.z < 1.0) {
                    out.visible = 0;
                }
            }
        }
    }
    
    
    return out;
}

fragment float4 meshFragment100(ColorInOut in [[ stage_in ]]) {
    if (in.visible != 0) {
        discard_fragment();
    }
    
    return float4(0,0,0,0);
}
