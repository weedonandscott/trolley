use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};

#[cfg(windows)]
const RT_ICON: u16 = 3;
#[cfg(windows)]
const RT_GROUP_ICON: u16 = 14;
#[cfg(windows)]
const MAIN_ICON_ID: u16 = 1;
const FIRST_IMAGE_ID: u16 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
struct IconImage {
    width: u8,
    height: u8,
    color_count: u8,
    reserved: u8,
    planes: u16,
    bit_count: u16,
    bytes: Vec<u8>,
}

pub fn stamp_exe_icon(exe_path: &Path, icon_path: &Path) -> Result<bool> {
    let images = parse_ico(icon_path)?;
    if images.is_empty() {
        bail!("ICO file contains no images: {}", icon_path.display());
    }

    #[cfg(windows)]
    {
        stamp_exe_icon_windows(exe_path, &images)
            .with_context(|| format!("updating Windows resources in {}", exe_path.display()))?;
        Ok(true)
    }

    #[cfg(not(windows))]
    {
        let _ = exe_path;
        let _ = images;
        Ok(false)
    }
}

fn parse_ico(icon_path: &Path) -> Result<Vec<IconImage>> {
    let data =
        fs::read(icon_path).with_context(|| format!("reading icon {}", icon_path.display()))?;
    if data.len() < 6 {
        bail!("ICO file is too small: {}", icon_path.display());
    }

    let reserved = read_u16(&data, 0)?;
    let file_type = read_u16(&data, 2)?;
    let count = read_u16(&data, 4)? as usize;
    if reserved != 0 || file_type != 1 {
        bail!("invalid ICO header in {}", icon_path.display());
    }
    if count == 0 {
        bail!("ICO file contains no images: {}", icon_path.display());
    }

    let entries_end = 6usize
        .checked_add(count.checked_mul(16).context("ICO entry count overflow")?)
        .context("ICO entry table overflow")?;
    if data.len() < entries_end {
        bail!("ICO entry table is truncated: {}", icon_path.display());
    }

    let mut images = Vec::with_capacity(count);
    for i in 0..count {
        let base = 6 + (i * 16);
        let image_size = read_u32(&data, base + 8)? as usize;
        let image_offset = read_u32(&data, base + 12)? as usize;
        let image_end = image_offset
            .checked_add(image_size)
            .context("ICO image data overflow")?;
        if image_end > data.len() {
            bail!("ICO image data is truncated: {}", icon_path.display());
        }

        images.push(IconImage {
            width: data[base],
            height: data[base + 1],
            color_count: data[base + 2],
            reserved: data[base + 3],
            planes: read_u16(&data, base + 4)?,
            bit_count: read_u16(&data, base + 6)?,
            bytes: data[image_offset..image_end].to_vec(),
        });
    }

    Ok(images)
}

fn build_group_icon_resource(images: &[IconImage]) -> Result<Vec<u8>> {
    let count = u16::try_from(images.len()).context("too many ICO images")?;
    let capacity = 6usize
        .checked_add(
            images
                .len()
                .checked_mul(14)
                .context("group icon entry overflow")?,
        )
        .context("group icon size overflow")?;
    let mut resource = Vec::with_capacity(capacity);
    resource.extend_from_slice(&0u16.to_le_bytes());
    resource.extend_from_slice(&1u16.to_le_bytes());
    resource.extend_from_slice(&count.to_le_bytes());

    for (index, image) in images.iter().enumerate() {
        let image_id = u16::try_from(index)
            .ok()
            .and_then(|v| v.checked_add(FIRST_IMAGE_ID))
            .context("too many ICO images for resource ids")?;
        let byte_len = u32::try_from(image.bytes.len()).context("icon image is too large")?;

        resource.push(image.width);
        resource.push(image.height);
        resource.push(image.color_count);
        resource.push(image.reserved);
        resource.extend_from_slice(&image.planes.to_le_bytes());
        resource.extend_from_slice(&image.bit_count.to_le_bytes());
        resource.extend_from_slice(&byte_len.to_le_bytes());
        resource.extend_from_slice(&image_id.to_le_bytes());
    }

    Ok(resource)
}

fn read_u16(data: &[u8], offset: usize) -> Result<u16> {
    let bytes = data
        .get(offset..offset + 2)
        .context("unexpected end of ICO data")?;
    Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
}

fn read_u32(data: &[u8], offset: usize) -> Result<u32> {
    let bytes = data
        .get(offset..offset + 4)
        .context("unexpected end of ICO data")?;
    Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

#[cfg(windows)]
fn stamp_exe_icon_windows(exe_path: &Path, images: &[IconImage]) -> Result<()> {
    use std::ffi::{OsStr, c_void};
    use std::os::windows::ffi::OsStrExt;
    use std::ptr;

    type Bool = i32;
    type Handle = *mut c_void;

    unsafe extern "system" {
        fn BeginUpdateResourceW(p_file_name: *const u16, delete_existing: Bool) -> Handle;
        fn UpdateResourceW(
            update: Handle,
            resource_type: *const u16,
            name: *const u16,
            language: u16,
            data: *mut c_void,
            data_size: u32,
        ) -> Bool;
        fn EndUpdateResourceW(update: Handle, discard: Bool) -> Bool;
    }

    fn wide_os(value: &OsStr) -> Vec<u16> {
        value.encode_wide().chain(std::iter::once(0)).collect()
    }

    fn make_int_resource(id: u16) -> *const u16 {
        id as usize as *const u16
    }

    struct UpdateGuard(Handle);

    impl Drop for UpdateGuard {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    let _ = EndUpdateResourceW(self.0, 1);
                }
            }
        }
    }

    let exe_wide = wide_os(exe_path.as_os_str());
    let update = unsafe { BeginUpdateResourceW(exe_wide.as_ptr(), 0) };
    if update.is_null() {
        return Err(std::io::Error::last_os_error()).context("BeginUpdateResourceW failed");
    }
    let mut guard = UpdateGuard(update);

    for (index, image) in images.iter().enumerate() {
        let image_id = u16::try_from(index)
            .ok()
            .and_then(|v| v.checked_add(FIRST_IMAGE_ID))
            .context("too many ICO images for resource ids")?;
        let byte_len = u32::try_from(image.bytes.len()).context("icon image is too large")?;
        let ok = unsafe {
            UpdateResourceW(
                guard.0,
                make_int_resource(RT_ICON),
                make_int_resource(image_id),
                0,
                image.bytes.as_ptr() as *mut c_void,
                byte_len,
            )
        };
        if ok == 0 {
            return Err(std::io::Error::last_os_error())
                .context("UpdateResourceW failed for RT_ICON");
        }
    }

    let mut group_resource = build_group_icon_resource(images)?;
    let group_len =
        u32::try_from(group_resource.len()).context("group icon resource is too large")?;
    let ok = unsafe {
        UpdateResourceW(
            guard.0,
            make_int_resource(RT_GROUP_ICON),
            make_int_resource(MAIN_ICON_ID),
            0,
            group_resource.as_mut_ptr() as *mut c_void,
            group_len,
        )
    };
    if ok == 0 {
        return Err(std::io::Error::last_os_error())
            .context("UpdateResourceW failed for RT_GROUP_ICON");
    }

    let ok = unsafe { EndUpdateResourceW(guard.0, 0) };
    if ok == 0 {
        return Err(std::io::Error::last_os_error()).context("EndUpdateResourceW failed");
    }
    guard.0 = ptr::null_mut();

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn single_icon_bytes() -> Vec<u8> {
        let image = [0x89, b'P', b'N', b'G'];
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.push(16);
        bytes.push(16);
        bytes.push(0);
        bytes.push(0);
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&32u16.to_le_bytes());
        bytes.extend_from_slice(&(image.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&(22u32).to_le_bytes());
        bytes.extend_from_slice(&image);
        bytes
    }

    #[test]
    fn parse_ico_reads_single_image() {
        let dir = tempfile::tempdir().unwrap();
        let icon_path = dir.path().join("app.ico");
        fs::write(&icon_path, single_icon_bytes()).unwrap();

        let images = parse_ico(&icon_path).unwrap();
        assert_eq!(images.len(), 1);
        assert_eq!(images[0].width, 16);
        assert_eq!(images[0].height, 16);
        assert_eq!(images[0].planes, 1);
        assert_eq!(images[0].bit_count, 32);
        assert_eq!(images[0].bytes, vec![0x89, b'P', b'N', b'G']);
    }

    #[test]
    fn build_group_icon_resource_uses_resource_ids() {
        let images = vec![IconImage {
            width: 32,
            height: 32,
            color_count: 0,
            reserved: 0,
            planes: 1,
            bit_count: 32,
            bytes: vec![1, 2, 3, 4],
        }];

        let resource = build_group_icon_resource(&images).unwrap();
        assert_eq!(&resource[0..6], &[0, 0, 1, 0, 1, 0]);
        assert_eq!(resource[6], 32);
        assert_eq!(resource[7], 32);
        assert_eq!(&resource[14..18], &[4, 0, 0, 0]);
        assert_eq!(&resource[18..20], &[1, 0]);
    }
}
